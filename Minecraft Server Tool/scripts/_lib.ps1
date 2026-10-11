# Helpers for the scripts that deal with more than one server, or that talk to
# Mojang / Spigot / BuildTools. Dot-sourced by update-spigot.ps1, maintenance.ps1
# and status.ps1. Unlike _shared.ps1 this loads no server by default.

. (Join-Path $PSScriptRoot "_settings.ps1")   # $serversDir, $BuildToolsDir, $PluginSources, ...
$libMcrcon     = Join-Path $binDir "mcrcon.exe"
$userAgent     = @{ 'User-Agent' = 'minecraft-server-tool/1.0' }

# One server's config as a hashtable, without touching the caller's variables.
# server.config.ps1 uses $PSScriptRoot for its log paths, which still resolves to
# its own folder when dot-sourced here.
function Get-ServerConfig([string]$Name) {
    $cfgPath = Join-Path $serversDir "$Name\server.config.ps1"
    if (-not (Test-Path $cfgPath)) { return $null }
    & {
        . $args[0]
        @{
            Folder      = $args[1]
            ServerName  = $ServerName
            ServiceName = $ServiceName
            ServerDir   = $ServerDir
            JarName     = $JarName
            RconHost    = $RconHost
            RconPort    = $RconPort
            RconPass    = $RconPass
            ServerLog   = $ServerLog
            ConfigPath  = $args[0]
        }
    } $cfgPath $Name
}

# Every server folder in servers\, i.e. every folder there with a config.
function Get-AllServers {
    Get-ChildItem $serversDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "server.config.ps1") } |
        ForEach-Object { Get-ServerConfig $_.Name }
}

function Test-ServiceRunning($cfg) {
    $s = Get-Service -Name $cfg.ServiceName -ErrorAction SilentlyContinue
    return ($s -and $s.Status -eq 'Running')
}

# Returns the server's reply, or $null if it isn't running. Checks the service
# first: mcrcon against a closed port is quick to fail, but there's no reason to try.
function Invoke-Rcon($cfg, [string]$Command) {
    if (-not (Test-ServiceRunning $cfg)) { return $null }
    $out = & $libMcrcon -H $cfg.RconHost -P $cfg.RconPort -p $cfg.RconPass $Command 2>&1 | ForEach-Object { "$_" } | Out-String
    return $out.Trim()
}

# Player count, or $null if the server can't be asked.
function Get-OnlineCount($cfg) {
    $r = Invoke-Rcon $cfg "list"
    if ($r -match 'There are (\d+) of') { return [int]$matches[1] }
    return $null
}

# Plain `say`. tellraw would allow colour, but Windows PowerShell 5.1 mangles the
# embedded double quotes its JSON needs when passing them to a native exe.
function Send-Say($cfg, [string]$Message) {
    if (Test-ServiceRunning $cfg) { Invoke-Rcon $cfg "say $Message" | Out-Null }
}

# What the server last booted as, from its own log: Spigot build number and MC version.
#   This server is running Spigot version 4655-Spigot-766de51-2d99c8e (MC: 26.3) ...
function Get-RunningSpigotBuild($cfg) {
    $rx = 'running Spigot version (\d+)-Spigot-\S+ \(MC: ([\d.]+)\)'
    foreach ($f in @((Join-Path $cfg.ServerDir "logs\latest.log"), $cfg.ServerLog)) {
        if (-not (Test-Path $f)) { continue }
        $hit = Select-String -Path $f -Pattern $rx -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($hit -and $hit.Line -match $rx) { return @{ Build = [int]$matches[1]; MC = $matches[2] } }
    }
    return $null
}

# The newest Minecraft release that Spigot can build, and its Spigot build number.
#
# Deliberately NOT `--rev latest`: Spigot's latest.json lags Mojang, sometimes by
# weeks (on 2026-09-26 it still pointed at a pre-26.3 build while 26.3.json existed).
# So ask Mojang for the actual latest release, then check Spigot has published it.
function Get-SpigotTarget([string]$FallbackMC) {
    $mojang = Invoke-RestMethod "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" -TimeoutSec 30
    $latest = $mojang.latest.release
    foreach ($ver in @($latest, $FallbackMC) | Where-Object { $_ } | Select-Object -Unique) {
        try {
            $j = Invoke-RestMethod "https://hub.spigotmc.org/versions/$ver.json" -TimeoutSec 30
            return @{
                MC            = $ver
                Build         = [int]$j.name
                ToolsVersion  = [int]$j.toolsVersion
                JavaVersions  = @($j.javaVersions)       # class-file versions, e.g. 69 = Java 25
                MojangLatest  = $latest
                SpigotHasLatest = ($ver -eq $latest)
            }
        } catch { }
    }
    throw "Spigot has no version JSON for $latest (Mojang latest) or $FallbackMC."
}

# BuildTools' git checkouts are owned by whoever first ran BuildTools (you), but
# maintenance and /update build as SYSTEM. Git refuses to touch a repo owned by
# another user ("detected dubious ownership"), and BuildTools reports that as
# "Something did not apply cleanly to Spigot-API". It broke every scheduled build
# until 2026-09-27.
#
# Fix: safe.directory = * in BuildTools' OWN portable git (its etc\gitconfig), which
# nothing else on the machine uses. Exact paths aren't enough: Spigot's patch script
# fetches from "Spigot-API/../../Bukkit", git checks that unnormalized path, and it
# never matches a trusted "BuildTools/Bukkit". Git 2.45 has no folder wildcards. It
# also covers the reverse: a repo re-cloned by SYSTEM would otherwise break builds run
# as you. Re-checked before every build, since a BuildTools update can re-extract git.
function Set-BuildToolsGitTrust {
    $git = Get-ChildItem $buildToolsDir -Directory -Filter "PortableGit*" -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter git.exe -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -like '*\cmd' } } |
        Select-Object -First 1
    if (-not $git) { Write-Host "  no BuildTools portable git found; skipping trust check"; return }
    $have = @(& $git.FullName config --system --get-all safe.directory 2>$null)
    if ($have -notcontains '*') { & $git.FullName config --system --add safe.directory '*'; Write-Host "  git: BuildTools' portable git now trusts its repos" }
}

function Get-RemoteBuildToolsNumber {
    [int](Invoke-RestMethod "https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/buildNumber" -TimeoutSec 30)
}

# Local BuildTools build: our marker file if we downloaded it, else what the last run logged.
function Get-LocalBuildToolsNumber {
    $marker = Join-Path $buildToolsDir "BuildTools.version"
    if (Test-Path $marker) { return [int](Get-Content $marker -Raw).Trim() }
    $log = Join-Path $buildToolsDir "BuildTools.log.txt"
    if (Test-Path $log) {
        $hit = Select-String -Path $log -Pattern 'Loading BuildTools version: .*\(#(\d+)\)' | Select-Object -First 1
        if ($hit -and $hit.Line -match '\(#(\d+)\)') { return [int]$matches[1] }
    }
    return 0
}

# Java major version of the java.exe a service runs.
function Get-ServiceJava($cfg) {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Services\$($cfg.ServiceName)\Parameters"
    $exe = (Get-ItemProperty $p -ErrorAction SilentlyContinue).Application
    if (-not $exe -or -not (Test-Path $exe)) { return $null }
    $v = & $exe -version 2>&1 | Out-String
    if ($v -match 'version "(\d+)') { return @{ Exe = $exe; Major = [int]$matches[1] } }
    return @{ Exe = $exe; Major = $null }
}

# --- plugins -------------------------------------------------------------------
# Which plugins update, and from where: $PluginSources in settings.defaults.ps1
# (override it in settings.ps1).
$pluginCacheDir = Join-Path $buildToolsDir "plugin-cache"

function Get-PluginYml([string]$Jar) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = $null
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($Jar)
        $e = $z.GetEntry('plugin.yml'); if (-not $e) { return $null }
        $sr = New-Object IO.StreamReader($e.Open()); $y = $sr.ReadToEnd(); $sr.Close()
        $name = if ($y -match "(?m)^name:\s*['""]?([^'""\r\n]+)") { $matches[1].Trim() } else { $null }
        $ver  = if ($y -match "(?m)^version:\s*['""]?([^'""\r\n]+)") { $matches[1].Trim() } else { $null }
        return @{ Name = $name; Version = $ver }
    } catch { return $null } finally { if ($z) { $z.Dispose() } }
}

function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }
function Get-Hash([string]$Path, [string]$Algo) { (Get-FileHash -Algorithm $Algo -LiteralPath $Path).Hash.ToLower() }

# Which build of each auto-updated plugin is installed. Needed for CI sources, which
# publish no checksum and reuse the same version string across many builds.
function Get-PluginState($cfg) {
    $f = Join-Path $cfg.ServerDir "plugin-versions.json"
    $h = @{}
    if (Test-Path $f) { (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    return $h
}
function Save-PluginState($cfg, $state) {
    $o = [ordered]@{}; foreach ($k in ($state.Keys | Sort-Object)) { $o[$k] = $state[$k] }
    [pscustomobject]$o | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $cfg.ServerDir "plugin-versions.json") -Encoding utf8
}

function Get-PluginRemote([string]$Name) {
    $s = $PluginSources[$Name]
    $ua = $userAgent
    if ($s.Kind -eq 'geysermc') {
        $r = Invoke-RestMethod "https://download.geysermc.org/v2/projects/$($s.Project)/versions/latest/builds/latest" -TimeoutSec 30 -Headers $ua
        return @{
            Build = [int]$r.build; Label = "$($r.version) build $($r.build)"; FileName = $s.FileName
            Url   = "https://download.geysermc.org/v2/projects/$($s.Project)/versions/$($r.version)/builds/$($r.build)/downloads/$($s.Platform)"
            Hash = ([string]$r.downloads.($s.Platform).sha256).ToLower(); HashAlgo = 'SHA256'
        }
    }
    if ($s.Kind -eq 'jenkins') {
        $r = Invoke-RestMethod "$($s.Base)/job/$($s.Job)/lastSuccessfulBuild/api/json?tree=number,artifacts[fileName,relativePath]" -TimeoutSec 30 -Headers $ua
        $a = @($r.artifacts | Where-Object { $_.fileName -match $s.Artifact }) | Select-Object -First 1
        if (-not $a) { throw "$($s.Job) #$($r.number) has no artifact matching $($s.Artifact)" }
        return @{
            Build = [int]$r.number; Label = "#$($r.number) ($($a.fileName))"; FileName = $a.fileName
            Url   = "$($s.Base)/job/$($s.Job)/$($r.number)/artifact/$($a.relativePath)"; Hash = $null; HashAlgo = $null
        }
    }
    if ($s.Kind -eq 'modrinth') {
        # Newest version that lists one of our loaders; its primary file.
        $loaders = [uri]::EscapeDataString((ConvertTo-Json @($s.Loaders) -Compress))
        # Assign first, then index: in Windows PowerShell 5.1, Invoke-RestMethod sends a
        # JSON array down the pipeline as ONE object, so piping it to Select-Object
        # -First 1 returns the whole array.
        $all = Invoke-RestMethod "https://api.modrinth.com/v2/project/$($s.Project)/version?loaders=$loaders" -TimeoutSec 30 -Headers $ua
        $v = if ($all -is [array]) { $all[0] } else { $all }
        if (-not $v) { throw "Modrinth has no $($s.Loaders -join '/') version of $($s.Project)" }
        $file = @($v.files | Where-Object { $_.primary }) | Select-Object -First 1
        if (-not $file) { $file = $v.files | Select-Object -First 1 }
        return @{
            Build = [string]$v.version_number; Label = "$($v.version_number) ($($v.date_published.Substring(0,10)))"; FileName = $file.filename
            Url = $file.url; Hash = ([string]$file.hashes.sha512).ToLower(); HashAlgo = 'SHA512'
        }
    }
    throw "Unknown plugin source kind '$($s.Kind)' for $Name"
}

# Download into the shared plugin cache (reused across servers), verify it's a jar.
function Save-PluginDownload([string]$Name, $remote) {
    New-Item -ItemType Directory $pluginCacheDir -Force | Out-Null
    $dest = Join-Path $pluginCacheDir ("{0}-{1}.jar" -f $Name, ($remote.Build -replace '[^\w.\-]', '_'))
    if ((Test-Path $dest) -and (-not $remote.Hash -or (Get-Hash $dest $remote.HashAlgo) -eq $remote.Hash)) { return $dest }
    $tmp = "$dest.download"
    Invoke-WebRequest $remote.Url -OutFile $tmp -UseBasicParsing -TimeoutSec 120 -Headers $userAgent
    $b = [IO.File]::ReadAllBytes($tmp)
    if ($b.Length -lt 10KB -or $b[0] -ne 0x50 -or $b[1] -ne 0x4B) { Remove-Item $tmp -Force; throw "$Name download isn't a jar." }
    if ($remote.Hash -and (Get-Hash $tmp $remote.HashAlgo) -ne $remote.Hash) { Remove-Item $tmp -Force; throw "$Name download failed its checksum." }
    Move-Item $tmp $dest -Force
    # keep the 3 newest cached builds per plugin
    Get-ChildItem $pluginCacheDir -Filter "$Name-*.jar" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force
    return $dest
}

# Every auto-updatable plugin installed on this server and whether it needs updating.
# -NoDownload (status checks) decides from checksums / recorded builds / version
# strings only, so it can report "unknown" for a CI plugin it has never recorded.
function Get-PluginUpdates($cfg, [switch]$NoDownload) {
    $state = Get-PluginState $cfg
    $out = @()
    $unlisted = @()
    foreach ($jar in Get-ChildItem (Join-Path $cfg.ServerDir "plugins") -Filter *.jar -ErrorAction SilentlyContinue) {
        $yml = Get-PluginYml $jar.FullName
        if (-not $yml) { continue }
        if (-not $PluginSources.Contains($yml.Name)) { $unlisted += @{ Jar = $jar; Yml = $yml }; continue }
        $name = $yml.Name
        $item = [pscustomobject]@{ Name = $name; LocalFile = $jar.FullName; LocalVersion = $yml.Version
            Remote = $null; Needed = $null; Cached = $null; Error = $null }
        try {
            $remote = Get-PluginRemote $name
            $item.Remote = $remote
            $localSha = Get-Sha256 $jar.FullName
            $rec = $state[$name]
            if ($remote.Hash) {
                $item.Needed = ((Get-Hash $jar.FullName $remote.HashAlgo) -ne $remote.Hash)
            } elseif ($rec -and $rec.Sha256 -eq $localSha) {
                $item.Needed = ([string]$rec.Build -ne [string]$remote.Build)
            } elseif ($NoDownload) {
                # Never recorded. A different version string means newer; the same one proves nothing.
                if ($remote.FileName -notlike "*$($yml.Version)*") { $item.Needed = $true }
            } else {
                $c = Save-PluginDownload $name $remote
                $item.Needed = ((Get-Sha256 $c) -ne $localSha)
                if (-not $item.Needed) { $state[$name] = @{ Build = $remote.Build; Sha256 = $localSha; File = $jar.Name } }
            }
            if ($item.Needed -and -not $NoDownload) { $item.Cached = Save-PluginDownload $name $remote }
        } catch { $item.Error = $_.Exception.Message }
        $out += $item
    }
    if ($AutoUpdateModrinthPlugins -and $unlisted) { $out += @(Get-ModrinthAutoUpdates $cfg $unlisted -NoDownload:$NoDownload) }
    if (-not $NoDownload) { Save-PluginState $cfg $state }
    return $out
}

# "26.3" / "1.21.11" as a [version]; $null for snapshots and pre-releases.
function ConvertTo-McVersion([string]$v) {
    if ($v -notmatch '^(\d+)(?:\.(\d+))?(?:\.(\d+))?$') { return $null }
    $parts = @($matches[1], $(if ($matches[2]) { $matches[2] } else { '0' }), $(if ($matches[3]) { $matches[3] } else { '0' }))
    return [version]($parts -join '.')
}

# Plugins not in $PluginSources, looked up on Modrinth by file hash. Modrinth can
# identify any jar downloaded from it, and returns the newest version for a list of
# hashes in one call. Filtered by loader (spigot/bukkit) but not by Minecraft
# version: plugin authors' version tags lag behind (Geyser runs fine on releases
# it isn't tagged for yet), so a strict filter would never find anything. Instead a
# candidate is skipped only if EVERY version it's tagged for is newer than the
# server's, and never if it's older than what's installed. Jars Modrinth doesn't
# know (from SpigotMC, Hangar, CI) are left alone.
function Get-ModrinthAutoUpdates($cfg, $unlisted, [switch]$NoDownload) {
    $byHash = @{}
    foreach ($u in $unlisted) { $byHash[(Get-Hash $u.Jar.FullName 'SHA512')] = $u }
    $hashes = @($byHash.Keys)
    try {
        $known  = Invoke-RestMethod -Method Post "https://api.modrinth.com/v2/version_files" -ContentType 'application/json' -Headers $userAgent -TimeoutSec 30 `
            -Body (@{ hashes = $hashes; algorithm = 'sha512' } | ConvertTo-Json -Compress)
        $latest = Invoke-RestMethod -Method Post "https://api.modrinth.com/v2/version_files/update" -ContentType 'application/json' -Headers $userAgent -TimeoutSec 30 `
            -Body (@{ hashes = $hashes; algorithm = 'sha512'; loaders = @('spigot','bukkit') } | ConvertTo-Json -Compress)
    } catch {
        Write-Host "  Modrinth lookup failed, skipping plugins not in `$PluginSources: $($_.Exception.Message)"
        return @()
    }
    $run = Get-RunningSpigotBuild $cfg
    $mc = if ($run) { ConvertTo-McVersion $run.MC } else { $null }
    $out = @()
    foreach ($h in $hashes) {
        $have = $known.PSObject.Properties[$h]
        $new  = $latest.PSObject.Properties[$h]
        if (-not $have -or -not $new) { continue }          # not a Modrinth jar
        $have = $have.Value; $new = $new.Value
        $u = $byHash[$h]
        $item = [pscustomobject]@{ Name = $u.Yml.Name; LocalFile = $u.Jar.FullName; LocalVersion = $u.Yml.Version
            Remote = $null; Needed = $false; Cached = $null; Error = $null; Source = 'Modrinth (auto)' }
        try {
            $file = @($new.files | Where-Object { $_.primary }) | Select-Object -First 1
            if (-not $file) { $file = @($new.files)[0] }
            $item.Remote = @{ Build = [string]$new.version_number; Label = "$($new.version_number) (Modrinth)"; FileName = $file.filename
                              Url = $file.url; Hash = ([string]$file.hashes.sha512).ToLower(); HashAlgo = 'SHA512' }
            $tagged = @($new.game_versions | ForEach-Object { ConvertTo-McVersion $_ } | Where-Object { $_ })
            $oldest = $tagged | Sort-Object | Select-Object -First 1
            if ($item.Remote.Hash -eq $h) {
                $item.Needed = $false
            } elseif ([datetime]$new.date_published -le [datetime]$have.date_published) {
                $item.Needed = $false                         # never downgrade
            } elseif ($mc -and $oldest -and $oldest -gt $mc) {
                $item.Needed = $false
                $item.Remote.Label += " needs Minecraft $oldest+, skipped"
            } else {
                $item.Needed = $true
                if (-not $NoDownload) { $item.Cached = Save-PluginDownload $item.Name $item.Remote }
            }
        } catch { $item.Error = $_.Exception.Message; $item.Needed = $null }
        $out += $item
    }
    return $out
}

# Keep the $Keep newest folders this tooling created under $Dir (matched by $Pattern).
# Anything else in there, like hand-made backups, is never touched.
function Remove-OldFolders([string]$Dir, [string]$Pattern, [int]$Keep) {
    if (-not (Test-Path $Dir)) { return }
    Get-ChildItem $Dir -Directory | Where-Object { $_.Name -match $Pattern } | Sort-Object Name -Descending |
        Select-Object -Skip $Keep | ForEach-Object { Remove-Item $_.FullName -Recurse -Force; Write-Host "  pruned $($_.Name)" }
}

function Format-Duration([double]$mins) {
    $d = [math]::Floor($mins / 1440); $h = [math]::Floor(($mins % 1440) / 60); $m = [math]::Round($mins % 60)
    if ($d -gt 0) { "{0}d {1}h" -f $d, $h } elseif ($h -gt 0) { "{0}h {1:00}m" -f $h, $m } else { "{0}m" -f $m }
}
