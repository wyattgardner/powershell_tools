param(
    [string]$Server,          # server folder; default from settings ($DefaultServer)
    [switch]$RequireConfirm,  # /update path only: a Minecraft version jump needs /update confirm
    [switch]$Force,           # the confirm itself (set from /update confirm's flag file)
    [switch]$CheckOnly,       # report what would happen, change nothing
    [switch]$BuildOnly,       # build Spigot / download plugins into the caches; server untouched
    [switch]$NoPlugins,       # Spigot only
    [switch]$Quiet,           # no in-game messages (maintenance does its own announcing)
    [int]$CountdownSeconds = -1   # -1 = settings' $UpdateCountdownSeconds
)

# Updates one server: Spigot (built with BuildTools for the actual latest Minecraft
# release) and the plugins listed in _lib.ps1's $PluginSources, with ONE restart.
# Run by update.cmd in the server folder, by /update in-game (the ServerToolUpdater
# plugin runs the "Minecraft Update - <server>" scheduled task, which runs this as
# SYSTEM outside the server's process tree), and by daily maintenance.
#
#   newer Spigot build, same Minecraft version -> applies
#   newer Minecraft version                    -> applies, EXCEPT via /update, which
#                                                 needs /update confirm (-RequireConfirm)
#   newer plugin build                         -> applies
#
# A Minecraft version jump backs up worlds + plugins + server config files first, to
# <server>\manual backups\, kept forever. Everything else relies on your own rolling
# backups (e.g. DriveBackupV2) plus the previous jars kept in "old jars" / "old plugins".
#
# Order keeps the server down as briefly as possible, and means a failed build or
# download never touches the server:
#   update BuildTools -> resolve targets -> build / download (server still up) -> warn
#   -> stop -> back up -> swap -> start -> verify -> roll everything back if it fails
#
# Exit codes: 0 updated / already current, 3 staged (-BuildOnly), 2 needs confirmation, 1 failed.

$scriptPath = $MyInvocation.MyCommand.Path
$toolsDir   = Split-Path -Parent $scriptPath
. (Join-Path $toolsDir "_shared.ps1")
. (Join-Path $toolsDir "_lib.ps1")
if ($CountdownSeconds -lt 0) { $CountdownSeconds = $UpdateCountdownSeconds }
if (-not $UpdatePlugins) { $NoPlugins = $true }

# Elevation is needed to stop/start the service and edit its parameters. Relaunch
# ourselves rather than via Invoke-SelfElevate, which would drop the switches.
if (-not $CheckOnly -and -not $BuildOnly -and -not (Test-Elevated)) {
    Write-Host "Not elevated. Relaunching with admin rights..."
    $cmd = "& '$scriptPath' -Server '$Server' -CountdownSeconds $CountdownSeconds"
    foreach ($sw in 'Force','RequireConfirm','NoPlugins','Quiet') { if ((Get-Variable $sw -ValueOnly)) { $cmd += " -$sw" } }
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd)
    exit
}

$logFile = Join-Path $serverDirLocal "update.log"
Start-Transcript -Path $logFile -Append | Out-Null
if ([Environment]::UserInteractive -and -not $Quiet) { $Host.UI.RawUI.WindowTitle = "update $ServerName" }

$cfg = Get-ServerConfig $Server
function Say($msg)  { if (-not $Quiet) { Send-Say $cfg "[Update] $msg" } }
function Done([int]$code, [string]$msg) {
    if ($msg) { Write-Host $msg }
    Write-Host "=== Update finished (exit $code) ==="
    Stop-Transcript | Out-Null
    if ([Environment]::UserInteractive -and -not $Quiet) { Close-Window $(if ($code -eq 0) { 10 } else { 30 }) }
    exit $code
}

Write-Host "`n=== Update started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') for $Server ==="

# /update confirm drops this flag file in the server folder; it counts as -Force once.
# Left alone by -CheckOnly / -BuildOnly so a pending confirm isn't used up by a dry pass.
$flag = Join-Path $ServerDir "update.force"
if (-not $CheckOnly -and -not $BuildOnly -and (Test-Path $flag)) {
    $Force = $true
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
    Write-Host "update.force flag found (from /update confirm). Treating as -Force."
}

# One run at a time: every server shares BuildTools, its git checkouts, and the
# plugin cache. A second run waits rather than failing.
$mutex = New-Object System.Threading.Mutex($false, "Global\MinecraftServerTool-BuildTools")
$haveLock = $false
try { $haveLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
if (-not $haveLock) {
    Write-Host "Another update is running. Waiting for it (up to 30 min)..."
    Say "Another server is updating first. Queued."
    try { $haveLock = $mutex.WaitOne([TimeSpan]::FromMinutes(30)) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
    if (-not $haveLock) { Done 1 "Timed out waiting for the other update." }
}

try {
    # --- 1. BuildTools itself ---------------------------------------------------
    Write-Host "`n--- BuildTools ---"
    New-Item -ItemType Directory $buildToolsDir -Force | Out-Null
    $btJar = Join-Path $buildToolsDir "BuildTools.jar"
    $local = Get-LocalBuildToolsNumber
    $remote = $null
    try { $remote = Get-RemoteBuildToolsNumber } catch { Write-Host "  couldn't reach Jenkins: $($_.Exception.Message)" }
    Write-Host "  local #$local, latest #$remote"
    if ($remote -and ($remote -gt $local -or -not (Test-Path $btJar))) {
        if ($CheckOnly) { Write-Host "  would download BuildTools #$remote" }
        else {
            $tmp = "$btJar.download"
            Write-Host "  downloading BuildTools #$remote..."
            Invoke-WebRequest "https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar" -OutFile $tmp -UseBasicParsing -TimeoutSec 120
            $head = [IO.File]::ReadAllBytes($tmp)[0..1]
            if ((Get-Item $tmp).Length -lt 1MB -or $head[0] -ne 0x50 -or $head[1] -ne 0x4B) {   # "PK": a real jar
                Remove-Item $tmp -Force
                throw "Downloaded BuildTools.jar doesn't look like a jar."
            }
            Move-Item $tmp $btJar -Force
            Set-Content (Join-Path $buildToolsDir "BuildTools.version") $remote
            Write-Host "  BuildTools updated to #$remote"
        }
    } elseif (-not (Test-Path $btJar)) {
        throw "No BuildTools.jar in $buildToolsDir and Jenkins unreachable."
    }

    # --- 2. Spigot: what we have vs what exists --------------------------------------
    Write-Host "`n--- Spigot ---"
    $cur = Get-RunningSpigotBuild $cfg
    $curMC = if ($cur) { $cur.MC } elseif ($JarName -match 'spigot-([\d.]+)\.jar') { $matches[1] } else { $null }
    $target = Get-SpigotTarget $curMC
    Write-Host ("  running : build {0}, MC {1}" -f $(if ($cur) { $cur.Build } else { '?' }), $curMC)
    Write-Host ("  newest  : build {0}, MC {1}  (Mojang latest release: {2})" -f $target.Build, $target.MC, $target.MojangLatest)
    if (-not $target.SpigotHasLatest) {
        Write-Host "  Spigot hasn't published $($target.MojangLatest) yet; only newer $($target.MC) builds count."
    }
    $needSpigot = -not ($cur -and $cur.Build -eq $target.Build -and $cur.MC -eq $target.MC)
    $mcJump = ($needSpigot -and $curMC -and $target.MC -ne $curMC)
    if ($needSpigot -and -not $UpdateSpigot) {
        Write-Host "  Spigot update available, but `$UpdateSpigot is off in settings. Skipping Spigot."
        $needSpigot = $false; $mcJump = $false
    }

    if ($needSpigot) {
        # Java: Spigot lists the class-file versions it accepts (69 = Java 25).
        $java = Get-ServiceJava $cfg
        if ($java -and $java.Major -and $target.JavaVersions.Count -gt 0) {
            $need = $target.JavaVersions | ForEach-Object { $_ - 44 }
            if ($need -notcontains $java.Major) {
                Write-Host "  Spigot $($target.MC) needs Java $($need -join ' or '); service runs Java $($java.Major). Skipping Spigot." -ForegroundColor Yellow
                Say "Spigot $($target.MC) needs Java $($need -join ' or ') and this server has Java $($java.Major); skipping the Spigot part."
                $needSpigot = $false; $mcJump = $false
            } else { Write-Host "  Java $($java.Major) OK (accepts $($need -join ', '))" }
        }
        if ($needSpigot -and $target.ToolsVersion -gt (Get-LocalBuildToolsNumber) -and -not $CheckOnly) {
            Write-Host "  Spigot $($target.MC) needs BuildTools #$($target.ToolsVersion)+; skipping Spigot." -ForegroundColor Yellow
            $needSpigot = $false; $mcJump = $false
        }
    }

    if ($mcJump -and $RequireConfirm -and -not $Force) {
        Say "Minecraft $($target.MC) is out. It upgrades the world for good and may break Bedrock until Geyser updates. An op can run /update confirm."
        Done 2 "Minecraft $curMC -> $($target.MC) needs /update confirm (update.cmd and maintenance apply it without asking)."
    }

    # --- 3. plugins ------------------------------------------------------------------
    $plugins = @()
    if (-not $NoPlugins) {
        Write-Host "`n--- Plugins ---"
        $plugins = @(Get-PluginUpdates $cfg -NoDownload:$CheckOnly)
        foreach ($p in $plugins) {
            $state = if ($p.Error) { "ERROR: $($p.Error)" } elseif ($p.Needed -eq $true) { "UPDATE -> $($p.Remote.Label)" } elseif ($p.Needed -eq $false) { "current ($($p.Remote.Label))" } else { "unknown until first update ($($p.Remote.Label))" }
            Write-Host ("  {0,-14} {1,-18} {2}" -f $p.Name, $p.LocalVersion, $state)
        }
        if (-not $plugins) { Write-Host "  none of the installed plugins are auto-updatable" }
    }
    $pluginUpdates = @($plugins | Where-Object { $_.Needed -eq $true -and ($CheckOnly -or $_.Cached) })

    if (-not $needSpigot -and -not $pluginUpdates) {
        Say "Everything's already current (Spigot $($target.MC) build $($target.Build)$(if ($plugins) { ', plugins' }))."
        Done 0 "Up to date."
    }

    $what = @()
    if ($needSpigot) { $what += "Spigot $($target.MC) build $($target.Build)" }
    if ($pluginUpdates) { $what += ($pluginUpdates | ForEach-Object { $_.Name }) }
    $whatText = $what -join ', '

    if ($CheckOnly) { Done 0 "Would update: $whatText" }

    # --- 4. build Spigot (server stays up), or reuse a cached build -------------------
    $newJarName = "spigot-$($target.MC).jar"
    $built = $null
    if ($needSpigot) {
        Write-Host "`n--- Build ---"
        $cacheDir = Join-Path $buildToolsDir "builds"
        New-Item -ItemType Directory $cacheDir -Force | Out-Null
        $built = Join-Path $cacheDir ("spigot-{0}-{1}.jar" -f $target.MC, $target.Build)
        # Each cached build has a .sha256 beside it, written when it was built. A
        # cached jar that no longer matches (disk trouble, a half-finished copy) is
        # rebuilt rather than installed.
        $builtSha = "$built.sha256"
        $cacheOk = (Test-Path $built) -and (Get-Item $built).Length -ge 10MB -and (Test-Path $builtSha) -and
                   ((Get-Content $builtSha -Raw).Trim() -eq (Get-Sha256 $built))
        if ((Test-Path $built) -and -not $cacheOk) { Write-Host "  cached build failed its checksum (or has none); rebuilding"; Remove-Item $built, $builtSha -Force -ErrorAction SilentlyContinue }
        if ($cacheOk) {
            Write-Host "  reusing cached build $built (checksum OK)"
        } else {
            Say "Building Spigot $($target.MC) build $($target.Build). The server stays up while it builds (1-3 min)."
            Set-BuildToolsGitTrust
            $stage = Join-Path $buildToolsDir "staging"
            if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
            New-Item -ItemType Directory $stage | Out-Null
            $javaExe = if ($java) { $java.Exe } else { "java" }
            $buildLog = Join-Path $buildToolsDir ("build-{0}-{1}.log" -f $target.MC, $target.Build)
            $t0 = Get-Date
            $p = Start-Process -FilePath $javaExe -WorkingDirectory $buildToolsDir -NoNewWindow -PassThru -Wait `
                -ArgumentList @('-jar', "`"$btJar`"", '--nogui', '--rev', $target.MC, '--output-dir', "`"$stage`"") `
                -RedirectStandardOutput $buildLog -RedirectStandardError "$buildLog.err"
            $out = Join-Path $stage $newJarName
            Write-Host ("  BuildTools exited {0} after {1:N0}s. Log: {2}" -f $p.ExitCode, ((Get-Date) - $t0).TotalSeconds, $buildLog)
            if ($p.ExitCode -ne 0 -or -not (Test-Path $out) -or (Get-Item $out).Length -lt 10MB) {
                Get-Content $buildLog -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { "    $_" }
                Say "Spigot build failed. Nothing was changed; the server keeps running as it was."
                Done 1 "Build failed."
            }
            Move-Item $out $built -Force
            Set-Content $builtSha (Get-Sha256 $built) -Encoding ascii
            Write-Host "  built $built ($([math]::Round((Get-Item $built).Length / 1MB)) MB)"
            Get-ChildItem $cacheDir -Filter "spigot-*.jar" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 4 |
                ForEach-Object { Remove-Item $_.FullName, "$($_.FullName).sha256" -Force -ErrorAction SilentlyContinue; Write-Host "  pruned old cached build $($_.Name)" }
        }
    }
    # 3, not 0, so maintenance can tell "staged, needs applying" from "nothing to do".
    if ($BuildOnly) { Done 3 "Staged ($whatText); server untouched (-BuildOnly)." }

    # --- 5. warn and stop -----------------------------------------------------------
    Write-Host "`n--- Restart for: $whatText ---"
    $online = Get-OnlineCount $cfg
    if ($online -gt 0 -and $CountdownSeconds -gt 0) {
        Write-Host "  $online online; counting down $CountdownSeconds s"
        $marks = @(60, 30, 10, 5) | Where-Object { $_ -le $CountdownSeconds }
        $left = $CountdownSeconds
        Say "Restarting in $left seconds to update $whatText. Back in about a minute."
        foreach ($m in $marks) {
            if ($m -ge $left) { continue }
            Start-Sleep -Seconds ($left - $m); $left = $m
            Say "Restarting in $left seconds."
        }
        Start-Sleep -Seconds $left
        Say "Restarting now."
    }

    & (Join-Path $toolsDir "shutdown-minecraft.ps1") -Server $Server
    if ((Get-Service $ServiceName).Status -ne 'Stopped') { throw "Service didn't stop; not touching anything." }

    # --- 6. back up on a Minecraft version jump ------------------------------------------
    # Only jumps get a manual backup: they permanently upgrade the world, and there's
    # no going back without one. Kept forever; nothing here ever prunes "manual backups".
    # Spigot builds and plugin updates are covered by your own rolling backups,
    # plus the old jars kept in "old jars" / "old plugins".
    # Taken with the server stopped, so it's consistent. Restoring = stop, copy these
    # back, put the matching jar from "old jars" back.
    $stamp = Get-Date -Format 'yyyy-MM-dd HHmm'
    $dest = $null
    if ($mcJump) {
        $was = if ($cur) { "$($cur.MC)-$($cur.Build)" } else { "unknown" }
        $dest = Join-Path $ServerDir ("manual backups\{0} pre-{1}-{2} (was {3})" -f $stamp, $target.MC, $target.Build, $was)
        Write-Host "`n--- Backup (Minecraft $curMC -> $($target.MC)) -> $dest ---"
        $level = "world"
        $props = Join-Path $ServerDir "server.properties"
        if (Test-Path $props) {
            $l = Select-String -Path $props -Pattern '^level-name=(.+)$' | Select-Object -First 1
            if ($l) { $level = $l.Matches[0].Groups[1].Value.Trim() }
        }
        foreach ($d in @($level, "${level}_nether", "${level}_the_end", "plugins")) {
            $src = Join-Path $ServerDir $d
            if (-not (Test-Path $src)) { continue }
            & robocopy $src (Join-Path $dest $d) /E /R:1 /W:1 /NFL /NDL /NJH /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed backing up $d (code $LASTEXITCODE). Server left stopped, nothing swapped." }
            Write-Host "  $d"
        }
        Get-ChildItem $ServerDir -File | Where-Object { $_.Extension -in '.yml','.yaml','.properties','.json','.txt','.xml','.bat' } |
            ForEach-Object { Copy-Item $_.FullName $dest -Force }
        Write-Host ("  total {0:N0} MB" -f ((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
    }

    # --- 7. swap -------------------------------------------------------------------------
    Write-Host "`n--- Swap ---"
    $oldJarPath = Join-Path $ServerDir $JarName
    $keptOld = $null
    $nameChanged = $false
    # From the registry, not `nssm get`: nssm writes UTF-16 to the console and
    # PowerShell captures it with NULs between every character.
    $oldParams = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters").AppParameters
    if ($needSpigot) {
        $oldDir = Join-Path $ServerDir "old jars"
        New-Item -ItemType Directory $oldDir -Force | Out-Null
        $oldTag = if ($cur) { "spigot-$($cur.MC)-$($cur.Build).jar" } else { "$JarName.$(Get-Date -Format yyyyMMddHHmm)" }
        $keptOld = Join-Path $oldDir $oldTag
        if (Test-Path $oldJarPath) { Copy-Item $oldJarPath $keptOld -Force; Write-Host "  kept old jar: $keptOld" }
        Copy-Item $built (Join-Path $ServerDir $newJarName) -Force
        if ((Get-Sha256 (Join-Path $ServerDir $newJarName)) -ne (Get-Sha256 $built)) { throw "Copy of $newJarName into the server doesn't match the build. Nothing started." }
        Write-Host "  installed $newJarName (build $($target.Build))"
        $nameChanged = ($newJarName -ne $JarName)
        if ($nameChanged) {
            (Get-Content $cfg.ConfigPath -Raw -Encoding UTF8) -replace ('\$JarName\s*=\s*"' + [regex]::Escape($JarName) + '"'), ('$JarName     = "' + $newJarName + '"') |
                Set-Content $cfg.ConfigPath -Encoding utf8 -NoNewline
            & $nssm set $ServiceName AppParameters ($oldParams -replace [regex]::Escape("-jar $JarName"), "-jar $newJarName") | Out-Null
            $bat = Join-Path $ServerDir "run-minecraft.bat"   # the README keeps flags in both places
            if (Test-Path $bat) { (Get-Content $bat -Raw -Encoding UTF8) -replace [regex]::Escape($JarName), $newJarName | Set-Content $bat -Encoding ascii -NoNewline }
            Write-Host "  jar name $JarName -> $newJarName (config, service, run-minecraft.bat)"
        }
    }

    $pluginsDir = Join-Path $ServerDir "plugins"
    $oldPluginsDir = Join-Path $ServerDir "old plugins\$stamp"
    $swapped = @()      # for rollback: what to remove, what to put back
    $pstate = Get-PluginState $cfg
    $pstateBefore = @{}; foreach ($k in $pstate.Keys) { $pstateBefore[$k] = $pstate[$k] }
    foreach ($p in $pluginUpdates) {
        New-Item -ItemType Directory $oldPluginsDir -Force | Out-Null
        $oldName = Split-Path $p.LocalFile -Leaf
        $kept = Join-Path $oldPluginsDir $oldName
        Move-Item $p.LocalFile $kept -Force
        $newPath = Join-Path $pluginsDir $p.Remote.FileName
        Copy-Item $p.Cached $newPath -Force
        if ((Get-Sha256 $newPath) -ne (Get-Sha256 $p.Cached)) { throw "Copy of $($p.Remote.FileName) doesn't match the download." }
        $swapped += @{ New = $newPath; Kept = $kept; Original = $p.LocalFile }
        $pstate[$p.Name] = @{ Build = $p.Remote.Build; Sha256 = (Get-Sha256 $newPath); File = $p.Remote.FileName }
        Write-Host ("  {0}: {1} -> {2}" -f $p.Name, $oldName, $p.Remote.FileName)
    }
    if ($pluginUpdates) { Save-PluginState $cfg $pstate }
    Remove-OldFolders (Join-Path $ServerDir "old plugins") '^\d{4}-\d{2}-\d{2} \d{4}$' 10

    # --- 8. start and verify ----------------------------------------------------------
    & (Join-Path $toolsDir "start-minecraft.ps1") -Server $Server
    Start-Sleep -Seconds 2
    $problems = @()
    $now = Get-RunningSpigotBuild $cfg
    if ($needSpigot -and -not ($now -and $now.Build -eq $target.Build)) {
        $problems += "Spigot came up as build $(if ($now) { $now.Build } else { 'nothing' }), expected $($target.Build)"
    }
    $latest = Join-Path $ServerDir "logs\latest.log"
    $logText = if (Test-Path $latest) { Get-Content $latest -Raw -Encoding UTF8 } else { "" }
    foreach ($p in $pluginUpdates) {
        $n = [regex]::Escape($p.Name)
        if ($logText -match "Error occurred while enabling $n" -or $logText -match "Could not load '.*$([regex]::Escape($p.Remote.FileName))'") {
            $problems += "$($p.Name) failed to load"
        } elseif ($logText -notmatch "Enabling $n v") {
            $problems += "$($p.Name) never enabled"
        }
    }
    if (-not $problems) {
        Write-Host "`n  Verified: $(if ($now) { "Spigot build $($now.Build), MC $($now.MC)" })$(if ($pluginUpdates) { '; plugins enabled: ' + (($pluginUpdates | ForEach-Object { $_.Name }) -join ', ') })."
        Say "Updated: $whatText."
        Done 0 "Updated."
    }

    # Something didn't come up: put it all back the way it was.
    Write-Host "`n  Problems: $($problems -join '; '). Rolling back." -ForegroundColor Red
    & (Join-Path $toolsDir "shutdown-minecraft.ps1") -Server $Server
    foreach ($s in $swapped) {
        if (Test-Path $s.New) { Remove-Item $s.New -Force }
        Move-Item $s.Kept $s.Original -Force
    }
    if ($swapped) { Save-PluginState $cfg $pstateBefore }
    if ($needSpigot) {
        if ($keptOld -and (Test-Path $keptOld)) { Copy-Item $keptOld $oldJarPath -Force }
        if ($nameChanged) {
            (Get-Content $cfg.ConfigPath -Raw -Encoding UTF8) -replace ('\$JarName\s*=\s*"' + [regex]::Escape($newJarName) + '"'), ('$JarName     = "' + $JarName + '"') |
                Set-Content $cfg.ConfigPath -Encoding utf8 -NoNewline
            & $nssm set $ServiceName AppParameters $oldParams | Out-Null
        }
    }
    # First install (no previous jar to go back to): leave it stopped rather than
    # restarting the same broken setup in a loop.
    if ($needSpigot -and -not ($keptOld -and (Test-Path $keptOld))) {
        Write-Host "  No previous Spigot jar to roll back to; leaving the server stopped." -ForegroundColor Yellow
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    } else {
        & (Join-Path $toolsDir "start-minecraft.ps1") -Server $Server
    }
    if ($dest) { Write-Host "  The world may already be upgraded. Pre-update backup: $dest" -ForegroundColor Yellow }
    Say "Update didn't take ($($problems -join '; ')). Rolled back to how it was."
    Done 1 "Rolled back."
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Say "Update failed: $($_.Exception.Message)"
    Done 1 ""
}
finally {
    if ($haveLock) { try { $mutex.ReleaseMutex() } catch { } }
}
