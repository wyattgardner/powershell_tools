# Installs or re-applies the Factorio server service. RUN ELEVATED (relaunches itself).
# Safe to re-run after changing settings.ps1.
#
#   1. nssm.exe into bin\ (pinned build, SHA-256 checked)
#   2. server\ files: settings, adminlist, whitelist (never overwritten once they exist)
#   3. Game folder: config-path.cfg (write-data in the game folder), mod-list (base only)
#   4. NSSM service running scripts\run-factorio.ps1: auto start, LocalSystem, restart
#      after exit, Ctrl+C to stop (saves)
#   5. Firewall rule for UDP $Port, limited to factorio.exe; removes factorio Block rules
#   6. Removes the old "Factorio Server" Task Scheduler setup if present
#   7. Nightly backup task
#   8. Starts the service and waits for "InGame"

param([switch]$NoPause)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
if (Invoke-Elevated $MyInvocation.MyCommand.Path $(if ($NoPause) { '-NoPause' })) { exit }
New-Item -ItemType Directory -Force $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'install.log') -Force | Out-Null

$failed = 0
function Step($label, [scriptblock]$block) {
    try { & $block; Write-Host "  OK   $label" -ForegroundColor Green }
    catch { Write-Host "  FAIL $label" -ForegroundColor Red; Write-Host "       $($_.Exception.Message)" -ForegroundColor Red; $script:failed++ }
}
function Quit($code) { Stop-Transcript | Out-Null; if (-not $NoPause) { Pause-IfInteractive }; exit $code }

Write-Host "`n=== Checks ===" -ForegroundColor Cyan
$ver = Get-FactorioVersion
if (-not $ver) { Write-Host "  factorio.exe not found at $FactorioExe. Install the game with steamcmd first (see README)." -ForegroundColor Red; Quit 1 }
Write-Host "  Factorio $ver at $GameDir"

Write-Host "`n=== NSSM ===" -ForegroundColor Cyan
Step 'nssm.exe' {
    $ok = (Test-Path $Nssm) -and ((Get-FileHash $Nssm -Algorithm SHA256).Hash -eq $NssmSha256)
    if ($ok) { return }
    New-Item -ItemType Directory -Force (Split-Path $Nssm) | Out-Null
    $tmp = Join-Path $env:TEMP ("nssm-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest $NssmUrl -OutFile "$tmp\nssm.zip" -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead("$tmp\nssm.zip")
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq $NssmEntry }
            if (-not $entry) { throw "$NssmEntry not in the zip" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, "$tmp\nssm.exe", $true)
        } finally { $zip.Dispose() }
        $hash = (Get-FileHash "$tmp\nssm.exe" -Algorithm SHA256).Hash
        if ($hash -ne $NssmSha256) { throw "nssm.exe hash mismatch ($hash)" }
        Copy-Item "$tmp\nssm.exe" $Nssm -Force
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if (-not (Test-Path $Nssm)) { Quit 1 }

Write-Host "`n=== Server files ($ServerDir) ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force $ServerDir, $BackupDir, $GameLogDir | Out-Null
Step 'server-settings.json' {
    if (Test-Path $SettingsJson) { return }
    # First install: take the one from the game folder if the server was set up by hand,
    # else start from Factorio's example.
    $src = @((Join-Path $GameDir 'data\server-settings.json'), (Join-Path $GameDir 'data\server-settings.example.json')) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $src) { throw 'No server-settings.json or example found in the game folder.' }
    Copy-Item $src $SettingsJson
    if ($src -like '*example*') { Write-Host '       Copied the example. Set name and game_password in it, then re-run.' -ForegroundColor Yellow }
}
foreach ($pair in @(@($AdminlistJson, 'server-adminlist.json'), @($WhitelistJson, 'server-whitelist.json'))) {
    $dest = $pair[0]; $name = $pair[1]
    Step $name {
        if (Test-Path $dest) { return }
        $old = Join-Path $GameDir $name
        if (Test-Path $old) { Copy-Item $old $dest } else { Set-Content $dest '[]' -Encoding ascii }
    }
}

Write-Host "`n=== Game folder ===" -ForegroundColor Cyan
Step 'config-path.cfg (write-data in game folder)' { Set-ConfigPath | Out-Null }
Step 'mods\mod-list.json (base only)' { Set-ModList }

Write-Host "`n=== Service '$ServiceName' ===" -ForegroundColor Cyan
# Stop the old Task Scheduler wrapper first so the port is free.
$oldTask = Get-ScheduledTask -TaskName 'Factorio Server' -ErrorAction SilentlyContinue
if ($oldTask) {
    Step 'remove old task "Factorio Server"' {
        if ($oldTask.State -eq 'Running') {
            Stop-ScheduledTask -TaskName 'Factorio Server'
            Get-Process factorio -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$GameDir\*" } | Stop-Process -Force
        }
        Unregister-ScheduledTask -TaskName 'Factorio Server' -Confirm:$false
    }
}
Step 'service config' {
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        try { Stop-Service $ServiceName -ErrorAction Stop }
        catch {
            # A crash-looping service sits in StartPending and may refuse a stop. End NSSM.
            $svcPid = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'").ProcessId
            if ($svcPid) { Stop-Process -Id $svcPid -Force -ErrorAction SilentlyContinue }
            Get-Process factorio -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            (Get-Service $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        Backup-Saves 'install' | Out-Null
    }
    # The service runs run-factorio.ps1, which starts factorio.exe. factorio.exe is a GUI
    # program with no console of its own, so run directly, NSSM's Ctrl+C can't reach it and
    # stops kill it unsaved. Via the wrapper it shares a console and saves (see the script).
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wrapper = Join-Path $PSScriptRoot 'run-factorio.ps1'
    if (-not $svc) { & $Nssm install $ServiceName $psExe | Out-Null }
    & $Nssm set $ServiceName Application $psExe | Out-Null
    & $Nssm set $ServiceName AppDirectory $GameDir | Out-Null
    & $Nssm set $ServiceName AppNoConsole 0 | Out-Null
    # AppParameters straight into the registry, not `nssm set`: Windows PowerShell 5.1 strips
    # embedded quotes from native-command arguments, and the paths contain "Server Tools".
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters" `
        -Name AppParameters -Value "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`"" -Type ExpandString
    & $Nssm set $ServiceName DisplayName $DisplayName | Out-Null
    & $Nssm set $ServiceName Description "Factorio dedicated server, UDP $Port. Managed by Server Tools\Factorio Server Tool." | Out-Null
    & $Nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
    & $Nssm set $ServiceName ObjectName LocalSystem | Out-Null
    # Stop = Ctrl+C first: Factorio saves the map and exits in well under a second.
    & $Nssm set $ServiceName AppStopMethodSkip 0 | Out-Null
    & $Nssm set $ServiceName AppStopMethodConsole 60000 | Out-Null
    & $Nssm set $ServiceName AppStopMethodWindow 10000 | Out-Null
    & $Nssm set $ServiceName AppStopMethodThreads 5000 | Out-Null
    # Any exit, crash or not, restarts it. Only stopping the service keeps it down.
    & $Nssm set $ServiceName AppExit Default Restart | Out-Null
    & $Nssm set $ServiceName AppRestartDelay ($RestartDelaySeconds * 1000) | Out-Null
    # Factorio writes its own logs (factorio-current.log, logs\console.log) and the wrapper
    # writes logs\service.log; no NSSM stdout capture, which would grow without limit
    # (NSSM 2.24 rotation is unreliable).
    # The service runs nssm.exe from this tool's bin\.
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    Set-ItemProperty -Path $key -Name ImagePath -Value "`"$Nssm`"" -Type ExpandString
    # If NSSM itself dies, the Service Control Manager restarts it after 60 s.
    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
}

Write-Host "`n=== Firewall ===" -ForegroundColor Cyan
Step "rule '$FirewallRuleName' (UDP $Port, factorio.exe only)" {
    $rule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
    if ($rule) {
        $rule | Set-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -Profile Any -RemoteAddress Any
        $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol UDP -LocalPort $Port
        $rule | Get-NetFirewallApplicationFilter | Set-NetFirewallApplicationFilter -Program $FactorioExe
    } else {
        New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound -Action Allow -Protocol UDP -LocalPort $Port `
            -Program $FactorioExe -RemoteAddress Any -Profile Any | Out-Null
    }
}
Step 'remove factorio Block rules' {
    $blocks = Get-NetFirewallRule | Where-Object { $_.DisplayName -like '*factorio*' -and $_.Action -eq 'Block' }
    foreach ($b in $blocks) { Write-Host "       removing '$($b.DisplayName)'"; $b | Remove-NetFirewallRule }
}

Write-Host "`n=== Nightly backup ===" -ForegroundColor Cyan
$bName = 'Factorio Nightly Backup'
if ($NightlyBackup) {
    Step "task '$bName' ($NightlyBackupTime)" {
        $cmd = "& '$((Join-Path $PSScriptRoot 'backup.ps1') -replace "'", "''")' -Reason nightly"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
        $trigger = New-ScheduledTaskTrigger -Daily -At $NightlyBackupTime
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $bName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'Copies the newest Factorio save to the tool''s server\backups folder.' -Force | Out-Null
    }
} elseif (Get-ScheduledTask -TaskName $bName -ErrorAction SilentlyContinue) {
    Step "remove task '$bName'" { Unregister-ScheduledTask -TaskName $bName -Confirm:$false }
}

Write-Host "`n=== Start ===" -ForegroundColor Cyan
$since = Get-Date
Step 'start service' { Start-Service $ServiceName }
if (Wait-Hosting -TimeoutSeconds 120 -Since $since) {
    Write-Host "  OK   hosting on UDP $Port" -ForegroundColor Green
} else {
    Write-Host "  FAIL not in game after 120 s. Check $CurrentLog" -ForegroundColor Red; $failed++
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Service:  $ServiceName ($((Get-Service $ServiceName).Status))"
Write-Host "  Version:  $ver"
Get-NetFirewallRule -DisplayName $FirewallRuleName | Get-NetFirewallPortFilter | ForEach-Object { Write-Host "  Firewall: $($_.Protocol) $($_.LocalPort)" }
Get-NetFirewallRule -DisplayName $FirewallRuleName | Get-NetFirewallApplicationFilter | ForEach-Object { Write-Host "  Program:  $($_.Program)" }
Write-Host "`n  One manual step if not done yet: register shutdown-gp.ps1 as a Group Policy"
Write-Host "  shutdown script (see README) so a reboot always saves the map first."
if ($failed) { Write-Host "`n$failed step(s) failed. See above." -ForegroundColor Red; Quit 1 }
Write-Host "`nDone." -ForegroundColor Green
Quit 0
