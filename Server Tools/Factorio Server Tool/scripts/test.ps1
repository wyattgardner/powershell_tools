# Checks the service does what it should. RUN ELEVATED (relaunches itself).
# Players get disconnected for about a minute.
#   1. Crash: kills factorio.exe; NSSM must restart it and it must get back in game
#   2. Stop:  stop.ps1 must save (Ctrl+C), back up, and stay stopped
#   3. Start: start.ps1 must load the map and host again
# Results: logs\test.log
param([switch]$NoPause)
. (Join-Path $PSScriptRoot '_common.ps1')
if (Invoke-Elevated $MyInvocation.MyCommand.Path) { exit }
$L = 'test.log'
$fail = 0
function Check($ok, $msg) {
    if ($ok) { Write-Log "  PASS $msg" $L Green } else { Write-Log "  FAIL $msg" $L Red; $script:fail++ }
}

try {
    Write-Log '=== Test run ===' $L Cyan
    if ((Get-Service $ServiceName).Status -ne 'Running') {
        Write-Log 'Service not running; starting it first.' $L
        & (Join-Path $PSScriptRoot 'start.ps1') -NoPause
    }

    # 1. Crash
    Write-Log '1. Crash: killing factorio.exe' $L
    $p = Get-Process factorio -ErrorAction Stop | Select-Object -First 1
    $since = Get-Date
    Stop-Process -Id $p.Id -Force
    $deadline = (Get-Date).AddSeconds(60); $new = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 1
        $new = Get-Process factorio -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $p.Id } | Select-Object -First 1
        if ($new) { break }
    }
    Check ([bool]$new) ("restarted" + $(if ($new) { " after $([int]($new.StartTime - $since).TotalSeconds) s (PID $($new.Id))" }))
    Check (Wait-Hosting -TimeoutSeconds 60 -Since $since) 'back in game'

    # 2. Stop
    Write-Log '2. Stop: stop.ps1' $L
    $before = @(Get-ChildItem $BackupDir -Filter *.zip -ErrorAction SilentlyContinue).Count
    & (Join-Path $PSScriptRoot 'stop.ps1') -NoPause -Reason 'test'
    Check ((Get-Service $ServiceName).Status -eq 'Stopped') 'service stopped'
    Check (Select-String $CurrentLog -Pattern 'Received SIGINT' -Quiet) 'got Ctrl+C'
    Check (Select-String $CurrentLog -Pattern 'Saving progress: 100' -Quiet) 'map saved'
    Check (@(Get-ChildItem $BackupDir -Filter *.zip).Count -gt $before -or $BackupKeep -le $before) 'backup copied'
    Start-Sleep 15
    Check (-not (Get-Process factorio -ErrorAction SilentlyContinue)) 'still stopped 15 s later (no restart)'

    # 3. Start
    Write-Log '3. Start: start.ps1' $L
    & (Join-Path $PSScriptRoot 'start.ps1') -NoPause
    Check ((Get-Service $ServiceName).Status -eq 'Running') 'service running'
    Check (Select-String $CurrentLog -Pattern 'Hosting game at' -Quiet) "hosting on UDP $Port"
}
catch { Write-Log "  ERROR $($_.Exception.Message)" $L Red; $fail++ }

if ($fail) { Write-Log "=== $fail check(s) failed ===" $L Red } else { Write-Log '=== All passed ===' $L Green }
if (-not $NoPause) { Pause-IfInteractive }
exit [int]($fail -gt 0)
