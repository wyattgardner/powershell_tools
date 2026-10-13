# Sets up one server from install.config.ps1. Run it with install.cmd.
#
#   1. Java (installs a JDK with winget if missing and allowed)
#   2. server folder from _template, with server.config.ps1 filled in
#   3. EULA, Windows service, log4j2.xml, server.properties, RCON firewall block
#      (install-server.ps1)
#   4. firewall rules for players
#   5. build Spigot and start the server (update-spigot.ps1)
#   6. /update and maintenance (install-automation.ps1)
#   7. shortcuts
#   8. shutdown script: the one manual step
#
# Re-running it for an existing server skips what's done and finishes the rest.
# Logs to install.log.

param([switch]$NoPause)    # no 'Enter to close' at the end (unattended runs)

$scriptPath = $MyInvocation.MyCommand.Path
$toolsDir   = Split-Path -Parent $scriptPath     # scripts\
$toolRoot   = Split-Path -Parent $toolsDir       # the tools folder
$logDir     = Join-Path $toolRoot "logs"
$cfgFile    = Join-Path $toolRoot "install.config.ps1"
$cfgDefault = Join-Path $toolRoot "install.config.defaults.ps1"

# First run: make the user's copy of the config and stop so they can edit it.
if (-not (Test-Path $cfgFile)) {
    Copy-Item $cfgDefault $cfgFile
    Write-Host "Created install.config.ps1. Edit it (at least `$ServerName and `$AcceptEula)," -ForegroundColor Yellow
    Write-Host "save it, and run install.cmd again." -ForegroundColor Yellow
    Start-Process notepad.exe $cfgFile
    Read-Host "Enter to close" | Out-Null
    exit 0
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not elevated. Relaunching with admin rights..."
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',
        "& '$($scriptPath -replace "'", "''")'$(if ($NoPause) { ' -NoPause' })")
    exit
}

New-Item -ItemType Directory $logDir -Force | Out-Null
Start-Transcript -Path (Join-Path $logDir "install.log") -Append | Out-Null
$closePause = -not $NoPause
$NoPause = $true    # the scripts this runs see it and skip their closing pauses
Write-Host "`n=== Install started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan

function Fail($msg) {
    Write-Host "`n$msg" -ForegroundColor Red
    Write-Host "Fix that, then run install.cmd again. Log: $(Join-Path $logDir 'install.log')"
    Stop-Transcript | Out-Null
    if ($closePause) { Read-Host "Enter to close" | Out-Null }
    exit 1
}
function Section($t) { Write-Host "`n--- $t ---" -ForegroundColor Cyan }

# Downloaded zips mark every file as from the internet; clear that so nothing prompts.
Get-ChildItem $toolRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

. $cfgDefault          # anything missing from an older install.config.ps1 keeps its default
. $cfgFile
. (Join-Path $toolsDir "_lib.ps1")

# --- 0. check the config -----------------------------------------------------------------
$ServerName = $ServerName.Trim()
if (-not $ServerName -or $ServerName -eq '_template' -or $ServerName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    Fail "`$ServerName '$ServerName' can't be used as a folder name."
}
$srvTools = Join-Path $serversDir $ServerName
$existing = Test-Path (Join-Path $srvTools "server.config.ps1")
if (-not $existing -and -not $AcceptEula) {
    Fail "Set `$AcceptEula = `$true in install.config.ps1 (you accept https://aka.ms/MinecraftEULA)."
}

# --- 1. NSSM, mcrcon, Java ---------------------------------------------------------------------
Section "NSSM and mcrcon"
if (-not (Install-ToolBinaries)) { Fail "Couldn't get nssm.exe / mcrcon.exe (see above)." }
# The LAN console folder is meant to be copied to another PC whole, so it gets its own mcrcon.
$lanMcrcon = Join-Path $toolRoot "lan-console\mcrcon.exe"
if (-not (Test-Path $lanMcrcon)) { Copy-Item (Join-Path $binDir "mcrcon.exe") $lanMcrcon }

Section "Java"
$java = $null
try { $java = Get-ToolJava } catch { }
if (-not $java -and $InstallJava) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { Fail "No JDK found and winget isn't available. Install a JDK 25 from https://adoptium.net/ and run install.cmd again." }
    Write-Host "  No JDK found. Installing Eclipse Temurin JDK 25 with winget..."
    & $winget.Source install --id EclipseAdoptium.Temurin.25.JDK --exact --source winget --silent --accept-package-agreements --accept-source-agreements
    try { $java = Get-ToolJava } catch { }
}
if (-not $java) { Fail "No JDK found. Install a JDK 25 from https://adoptium.net/, or set `$JavaPath in settings.ps1." }
$javac = Join-Path (Split-Path $java) "javac.exe"
$ver = (& $java -version 2>&1 | ForEach-Object { "$_" }) -join "`n"
Write-Host "  $java"
Write-Host "  $(($ver -split "`n")[0].Trim())"
if (-not (Test-Path $javac)) { Fail "$java is a JRE, not a JDK. Install a JDK 25 from https://adoptium.net/." }

# --- 2. server folder -------------------------------------------------------------------------
Section "Server folder: $ServerName"
if ($existing) {
    Write-Host "  Already exists; using its server.config.ps1 as-is."
} else {
    $others = @(Get-AllServers)
    $usedPorts = @()
    foreach ($o in $others) {
        $usedPorts += [int]$o.RconPort
        $gp = & { . $args[0]; $GamePort } $o.ConfigPath
        if ($gp) { $usedPorts += [int]$gp }
    }
    $listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object LocalPort)
    function Get-FreePort([int]$from) {
        $p = $from
        while ($usedPorts -contains $p -or $listening -contains $p) { $p++ }
        $script:usedPorts += $p
        return $p
    }
    if (-not $ServiceName) { $ServiceName = "minecraft-" + (($ServerName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')) }
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) { Fail "A Windows service named '$ServiceName' already exists. Set a different `$ServiceName." }
    if (-not $ServerDir) { $ServerDir = Join-Path "C:\MinecraftServers" $ServerName }
    if ($GamePort) { $usedPorts += [int]$GamePort } else { $GamePort = Get-FreePort 25565 }
    if ($RconPort) { $usedPorts += [int]$RconPort } else { $RconPort = Get-FreePort 25575 }
    # UDP, for Geyser. Picked now so it's set before Geyser could ever start with 19132.
    if (-not $BedrockPort) { $BedrockPort = Get-FreeBedrockPort $ServerName }
    if (-not $RconPass) { $RconPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }) }

    $jar = Get-ChildItem $ServerDir -Filter "spigot*.jar" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    New-Item -ItemType Directory $srvTools -Force | Out-Null
    Get-ChildItem (Join-Path $toolRoot "_template") -File | Where-Object { $_.Name -ne 'log4j2.xml' } | Copy-Item -Destination $srvTools
    $cfgPath = Join-Path $srvTools "server.config.ps1"
    $text = Get-Content $cfgPath -Raw -Encoding UTF8
    $values = [ordered]@{ ServerName = $ServerName; ServiceName = $ServiceName; ServerDir = $ServerDir; Heap = $Heap
                          RconPort = "$RconPort"; RconPass = $RconPass; GamePort = "$GamePort"; BedrockPort = "$BedrockPort" }
    if ($jar) { $values.JarName = $jar.Name }
    foreach ($k in $values.Keys) {
        $v = $values[$k] -replace '"', '`"'
        $text = [regex]::Replace($text, "(?m)^\`$$k(\s*)=\s*`"[^`"]*`"", { param($m) "`$$k$($m.Groups[1].Value)= `"$v`"" })
    }
    $text = $text -replace '(?s)^# TEMPLATE\..*?\r?\n\r?\n', "# Written by install.cmd. Edit freely; re-run install-server.cmd after changing anything.`r`n`r`n"
    Set-Content $cfgPath $text -Encoding utf8 -NoNewline
    Write-Host "  $srvTools"
    Write-Host "  service $ServiceName, game port $GamePort, RCON port $RconPort, Bedrock port $BedrockPort (if Geyser), heap $Heap"
    Write-Host "  server files: $ServerDir$(if ($jar) { " (using existing $($jar.Name))" })"
}
$s = Get-ServerConfig $ServerName
$gamePortNow = & { . $args[0]; $GamePort } $s.ConfigPath
# An older server may have no $BedrockPort: then whatever its Geyser uses, else Bedrock's default.
function Get-BedrockPortNow { $c = Get-ServerConfig $ServerName; if ($c.BedrockPort) { [int]$c.BedrockPort } elseif ($g = Get-GeyserPort $c.ServerDir) { $g } else { 19132 } }
function Test-BedrockOpen([int]$port) {
    @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Minecraft Bedrock*' } |
        Get-NetFirewallPortFilter | Where-Object { $_.Protocol -eq 'UDP' -and $_.LocalPort -eq "$port" }).Count -gt 0
}

# --- 3. EULA + service ------------------------------------------------------------------------
Section "Service"
New-Item -ItemType Directory $s.ServerDir -Force | Out-Null
$eula = Join-Path $s.ServerDir "eula.txt"
# Test-Path first: Select-String on a missing file throws an error that skips the whole if.
$eulaOk = (Test-Path $eula) -and (Select-String -Path $eula -Pattern '^eula=true' -Quiet)
if ($AcceptEula -and -not $eulaOk) {
    "# Accepted via install.cmd ($(Get-Date -Format 'yyyy-MM-dd')): https://aka.ms/MinecraftEULA`r`neula=true" | Set-Content $eula -Encoding ascii
    Write-Host "  EULA accepted (eula.txt)."
}
try { & (Join-Path $toolsDir "install-server.ps1") -Server $ServerName -NoPause }
catch { Fail "install-server failed: $($_.Exception.Message)" }
if (-not (Get-Service $s.ServiceName -ErrorAction SilentlyContinue)) { Fail "The service didn't install. See servers\$ServerName\install-server.log." }

# --- 4. firewall for players ---------------------------------------------------------------------
Section "Firewall"
function Add-Allow($name, $proto, $port) {
    if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) { Write-Host "  exists: $name"; return }
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol $proto -LocalPort $port | Out-Null
    Write-Host "  added: $name"
}
if ($OpenGamePort)    { Add-Allow "Minecraft $gamePortNow ($ServerName)" TCP $gamePortNow }
if ($OpenBedrockPort) { $bp = Get-BedrockPortNow; if (Test-BedrockOpen $bp) { Write-Host "  exists: UDP $bp (Bedrock)" } else { Add-Allow "Minecraft Bedrock $bp ($ServerName)" UDP $bp } }
if (-not $OpenGamePort -and -not $OpenBedrockPort) { Write-Host "  skipped (off in install.config.ps1)" }

# --- 4b. plugins from spigot_plugins.ps1 -----------------------------------------------------------
# New servers only, before the first start so they load right away. An existing server
# keeps the plugins it has; install-plugins.cmd adds the list to it on purpose.
Section "Plugins"
if ($existing) {
    Write-Host "  Existing server: left as is. To add the plugins on your list: install-plugins.cmd `"$ServerName`""
} else {
    Install-ListedPlugins $s | Out-Null
}
# Bedrock players need both the open UDP port and Geyser + Floodgate.
$pluginNames = @(Get-ChildItem (Join-Path $s.ServerDir "plugins") -Filter *.jar -File -ErrorAction SilentlyContinue |
    ForEach-Object { (Get-PluginYml $_.FullName).Name })
$hasGeyser = ($pluginNames -contains 'Geyser-Spigot') -and ($pluginNames -contains 'floodgate')
$bp = Get-BedrockPortNow
if ($OpenBedrockPort -and -not $hasGeyser) {
    Write-Host "  UDP $bp is open for Bedrock players, but they also need Geyser and Floodgate. They're in" -ForegroundColor Yellow
    Write-Host "  spigot_plugins.example.ps1: copy them into spigot_plugins.ps1, then install-plugins.cmd `"$ServerName`"." -ForegroundColor Yellow
} elseif ($hasGeyser -and -not (Test-BedrockOpen $bp)) {
    Write-Host "  Geyser is installed on UDP $bp, but that port isn't open, so Bedrock players can't connect yet." -ForegroundColor Yellow
    Write-Host "  Set `$OpenBedrockPort = `$true in install.config.ps1 and run install.cmd again." -ForegroundColor Yellow
} elseif ($hasGeyser) {
    Write-Host "  Bedrock players connect on UDP port $bp."
}

# --- 5. build and start ---------------------------------------------------------------------------
if ($BuildAndStart) {
    Section "Spigot: build and start (a few minutes the first time)"
    & (Join-Path $toolsDir "update-spigot.ps1") -Server $ServerName -Quiet -CountdownSeconds 0
    $code = $LASTEXITCODE
    # Exit code, not service status: NSSM shows Running even while the server crash-loops.
    if ($code -eq 0) { Write-Host "  Server is up." -ForegroundColor Green }
    else { Write-Host "  The server didn't come up (update exit $code). See servers\$ServerName\update.log and minecraft.log." -ForegroundColor Yellow }
}

# --- 6. automation --------------------------------------------------------------------------------
if ($InstallAutomation) {
    Section "Automation"
    & (Join-Path $toolsDir "install-automation.ps1") -NoPause
}

# --- 7. shortcuts -----------------------------------------------------------------------------------
Section "Shortcuts"
$sh = New-Object -ComObject WScript.Shell
function New-Shortcut($lnk, $target) {
    New-Item -ItemType Directory (Split-Path $lnk) -Force | Out-Null
    $l = $sh.CreateShortcut($lnk); $l.TargetPath = $target; $l.WorkingDirectory = Split-Path $target; $l.Save()
    Write-Host "  $lnk"
}
if ($DesktopShortcuts) {
    $dir = Join-Path ([Environment]::GetFolderPath('Desktop')) "Minecraft Servers\$ServerName"
    foreach ($c in 'console','start','stop','update') { New-Shortcut (Join-Path $dir "$c.lnk") (Join-Path $srvTools "$c.cmd") }
}
if ($StartupConsole) {
    New-Shortcut (Join-Path ([Environment]::GetFolderPath('Startup')) "$ServerName console.lnk") (Join-Path $srvTools "console.cmd")
}
if (-not $DesktopShortcuts -and -not $StartupConsole) { Write-Host "  none (off in install.config.ps1)" }

# --- 8. shutdown script ----------------------------------------------------------------------------
Section "Last step, by hand: save the world when Windows shuts down"
$gp = Join-Path $srvTools "shutdown-gp.ps1"
$ini = Join-Path $env:WINDIR "System32\GroupPolicy\Machine\Scripts\psscripts.ini"
if ((Test-Path $ini) -and (Select-String -LiteralPath $ini -Pattern ([regex]::Escape($gp)) -Quiet -Encoding Unicode)) {
    Write-Host "  Already registered." -ForegroundColor Green
} else {
    Write-Host "  In the Group Policy editor:"
    Write-Host "    Computer Configuration > Windows Settings > Scripts (Startup/Shutdown)"
    Write-Host "    > Shutdown > PowerShell Scripts tab > Add"
    Write-Host "    Script name: $gp"
    Write-Host "    Script Parameters: leave EMPTY"
    $gpedit = Join-Path $env:WINDIR "System32\gpedit.msc"
    if (-not (Test-Path $gpedit)) {
        Write-Host "  This Windows edition has no Group Policy editor (Home). Use stop.cmd before" -ForegroundColor Yellow
        Write-Host "  shutting down or rebooting, or the server is killed without saving its latest changes." -ForegroundColor Yellow
    } elseif ($OpenShutdownScriptSetup) {
        Set-Clipboard -Value $gp
        Start-Process mmc.exe $gpedit
        Write-Host "  Opened it. The script path is on your clipboard." -ForegroundColor Green
    }
}

# --- summary ---------------------------------------------------------------------------------------
Section "Done"
Write-Host "  Server   : $ServerName ($($s.ServiceName), $((Get-Service $s.ServiceName).Status))"
Write-Host "  Connect  : localhost:$gamePortNow from this PC; <this PC's IP>:$gamePortNow on your network"
Write-Host "  Console  : servers\$ServerName\console.cmd"
Write-Host "  Settings : servers\$ServerName\server.config.ps1 (this server), settings.ps1 (this machine)"
Write-Host "  Log      : $(Join-Path $logDir 'install.log')"
Stop-Transcript | Out-Null
if ($closePause) { Read-Host "`nEnter to close" | Out-Null }
