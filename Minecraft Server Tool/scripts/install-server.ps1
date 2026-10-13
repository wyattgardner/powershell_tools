param(
    [string]$Server,
    [switch]$NoPause    # used by install.ps1: no pause, no to-do list (it does those steps itself)
)

# Installs (or reconfigures) the Windows service for one server, using that
# server's config as the source of truth. Run elevated. Safe to re-run.
#
#   .\install-server.ps1 -Server "My New Server"
#
# Also, if they aren't already:
#   - copies log4j2.xml from _template into the server folder (ISO log timestamps)
#   - sets enable-rcon, rcon.port, rcon.password and server-port in server.properties
#   - adds a firewall rule blocking the RCON port from the internet
#
# Every setting here was arrived at the hard way; the comments say why.

if (-not $Server) {
    . (Join-Path $PSScriptRoot "_settings.ps1")
    Write-Host "Usage: install-server.cmd `"<server name>`"" -ForegroundColor Yellow
    Write-Host "Servers:"
    Get-ChildItem $serversDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "server.config.ps1") } |
        ForEach-Object { Write-Host "  $($_.Name)" }
    exit 1
}

$scriptPath = $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $scriptPath) "_shared.ps1")

if (-not (Test-Elevated)) { Invoke-SelfElevate $scriptPath $Server; exit }

Start-Transcript -Path (Join-Path $serverDirLocal "install-server.log") -Force | Out-Null

foreach ($v in 'ServerName','ServiceName','ServerDir','RconPass') {
    if ((Get-Variable $v -ValueOnly) -match 'CHANGE.?ME') {
        Write-Host "server.config.ps1 still has `$$v = CHANGE ME. Edit it first: $configPath" -ForegroundColor Red
        Stop-Transcript | Out-Null; Close-Window 20; exit 1
    }
}
if (-not (Test-Path $ServerDir)) { New-Item -ItemType Directory $ServerDir -Force | Out-Null; Write-Host "Created $ServerDir" }

try { $javaExe = Get-ToolJava } catch { Write-Host $_.Exception.Message -ForegroundColor Red; Stop-Transcript | Out-Null; Close-Window 20; exit 1 }
Write-Host "Java: $javaExe"

$jvmArgs = "-Xms$Heap -Xmx$Heap -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dlog4j.configurationFile=log4j2.xml --enable-native-access=ALL-UNNAMED -jar $JarName -nogui"

Write-Host "Installing service '$ServiceName' for '$ServerName'..."
if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) { & $nssm install $ServiceName $javaExe }
& $nssm set $ServiceName Application $javaExe
& $nssm set $ServiceName AppDirectory $ServerDir
& $nssm set $ServiceName AppParameters $jvmArgs
& $nssm set $ServiceName DisplayName "Minecraft: $ServerName"
& $nssm set $ServiceName Start SERVICE_AUTO_START
& $nssm set $ServiceName ObjectName LocalSystem
& $nssm set $ServiceName AppStdout $ServerLog
& $nssm set $ServiceName AppStderr $ServerLog
& $nssm set $ServiceName AppRestartDelay 5000
& $nssm set $ServiceName AppStopMethodSkip 0
& $nssm set $ServiceName AppStopMethodConsole 30000
& $nssm set $ServiceName AppStopMethodWindow 30000
& $nssm set $ServiceName AppStopMethodThreads 5000

# Restart on any exit. The second line matters: without it a CLEAN exit (code 0,
# e.g. someone typing "stop") leaves the service marked Running with no server
# behind it, and nothing brings it back.
& $nssm set $ServiceName AppExit Default Restart
& $nssm set $ServiceName AppExit 0 Restart

# Do NOT enable AppRotate*. With rotation on, NSSM 2.24 silently abandons its
# restart when the app exits. Proven by A/B test. Spigot rotates its own logs.

# The service runs nssm.exe itself, from whichever tools folder installed it. `nssm set`
# never changes that, so after moving the tools folder the service would still run the
# old folder's nssm.exe. Point it at this folder's, quoted: NSSM writes ImagePath
# unquoted, and an unquoted path with a space in it won't start.
$key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$img = (Get-ItemProperty $key).ImagePath
if ($img -ne "`"$nssm`"") {
    Set-ItemProperty -Path $key -Name ImagePath -Value "`"$nssm`"" -Type ExpandString
    if ($img.Trim('"') -ne $nssm) { Write-Host "Service now runs $nssm (was $img). Takes effect at its next start." }
    else { Write-Host "Quoted ImagePath." }
}

# --- log4j2.xml ------------------------------------------------------------------------
$log4j = Join-Path $ServerDir "log4j2.xml"
if (-not (Test-Path $log4j)) {
    Copy-Item (Join-Path $toolRoot "_template\log4j2.xml") $log4j
    Write-Host "Copied log4j2.xml (ISO timestamps; start-minecraft.ps1 depends on them)."
}

# --- server.properties -------------------------------------------------------------------
# Created if missing: Minecraft keeps what's there and fills in the rest on first start.
# Other lines are left as they are.
$props = Join-Path $ServerDir "server.properties"
$todo = @()
$want = [ordered]@{ 'enable-rcon' = 'true'; 'rcon.port' = $RconPort; 'rcon.password' = $RconPass; 'server-port' = $GamePort }
$lines = New-Object Collections.Generic.List[string]
if (Test-Path $props) { foreach ($l in @(Get-Content $props -Encoding UTF8)) { $lines.Add($l) } }
$changed = @()
foreach ($k in $want.Keys) {
    $line = "$k=$($want[$k])"
    $i = -1
    for ($n = 0; $n -lt $lines.Count; $n++) { if ($lines[$n] -match "^$([regex]::Escape($k))=") { $i = $n; break } }
    if ($i -lt 0) { $lines.Add($line); $changed += $k }
    elseif ($lines[$i] -ne $line) { $lines[$i] = $line; $changed += $k }
}
if ($changed) {
    $lines | Set-Content $props -Encoding ascii
    Write-Host "server.properties: set $($changed -join ', ')$(if ((Get-Service $ServiceName).Status -eq 'Running') { ' (restart the server to apply)' })."
}

# --- Geyser's Bedrock port ---------------------------------------------------------------------
# Only when this server has a $BedrockPort and Geyser: Geyser's config follows server.config.ps1.
. (Join-Path $toolsDir "_lib.ps1")
$geyserPort = Get-GeyserPort $ServerDir
if ($BedrockPort -and $null -ne $geyserPort -and $geyserPort -ne [int]$BedrockPort) {
    Set-GeyserPort $ServerDir ([int]$BedrockPort)
    Write-Host "Geyser: Bedrock port $geyserPort -> $BedrockPort$(if ((Get-Service $ServiceName).Status -eq 'Running') { ' (restart the server to apply)' })."
}

# --- firewall ---------------------------------------------------------------------------------
# RCON listens on all interfaces and the protocol is unencrypted. Block beats Allow in
# Windows Firewall, so this wins over any broad java.exe Allow rule; LAN still works.
$fwName = "Block Minecraft RCON $RconPort from Internet"
if (-not (Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Block -Protocol TCP -LocalPort $RconPort -RemoteAddress Internet | Out-Null
    Write-Host "Firewall: added '$fwName'."
}

# --- what's left -----------------------------------------------------------------------------------
if (-not (Test-Path (Join-Path $ServerDir $JarName))) {
    $todo += "no $JarName in $ServerDir yet. Run update.cmd in this server's folder to build it (or put a Spigot jar there and set `$JarName)"
}
$eula = Join-Path $ServerDir "eula.txt"
if (-not (Test-Path $eula) -or -not (Select-String -Path $eula -Pattern '^eula=true' -Quiet)) {
    $todo += "accept the Minecraft EULA: eula=true in $eula (https://aka.ms/MinecraftEULA)"
}
$todo += "allow players in: inbound TCP $GamePort in Windows Firewall (plus UDP $(if ($BedrockPort) { $BedrockPort } else { '19132' }) if you run Geyser), and port-forward it on your router for internet play"
$todo += "register '$serverDirLocal\shutdown-gp.ps1' as a Group Policy shutdown script, Parameters EMPTY (README: Shutdown scripts)"
$todo += "run install-automation.ps1 (elevated) so this server gets /update and maintenance"

Write-Host ""
if ($NoPause) { Write-Host "Service installed." -ForegroundColor Green }
else {
    Write-Host "Service installed. Still to do for this server:" -ForegroundColor Yellow
    $todo | ForEach-Object { Write-Host "  - $_" }
}
Stop-Transcript | Out-Null
Close-Window 30
