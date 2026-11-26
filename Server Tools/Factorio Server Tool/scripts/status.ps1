# Shows whether the server is up and what it's doing. No admin needed.
param([switch]$NoPause)
. (Join-Path $PSScriptRoot '_common.ps1')

# Each line goes to the screen and to logs\status.log.
function Line($label, $value, $color = 'Gray') {
    Write-Host ('  {0,-14} ' -f $label) -NoNewline; Write-Host $value -ForegroundColor $color
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    Add-Content (Join-Path $LogDir 'status.log') ('{0}  {1,-14} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $label, $value) -Encoding utf8
}

Write-Host "`n=== Factorio server ===" -ForegroundColor Cyan
$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) { Line 'Service' 'not installed (run install.cmd)' Red }
else { Line 'Service' "$($svc.Status), start type $($svc.StartType)" $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' }) }

Line 'Version' $(Get-FactorioVersion)

# NSSM shows Running even while factorio.exe crash-loops, so read the game's log too.
if (Test-Path $CurrentLog) {
    $log = Get-Content $CurrentLog
    $updated = (Get-Item $CurrentLog).LastWriteTime
    $inGame  = $log -match 'to\(InGame\)'
    $closed  = $log -match 'Goodbye'
    $state = if ($closed) { 'exited' } elseif ($inGame) { 'in game' } else { 'starting or failed' }
    Line 'Game' "$state (log updated $($updated.ToString('yyyy-MM-dd HH:mm')))" $(if ($inGame -and -not $closed) { 'Green' } else { 'Yellow' })
    $map = $log | Select-String 'Loading map (.+\.zip)' | Select-Object -Last 1
    if ($map) { Line 'Map' (Split-Path -Leaf $map.Matches[0].Groups[1].Value) }
    $err = $log | Select-String 'Error' | Select-Object -Last 1
    if ($err) { Line 'Last error' $err.Line.Trim() Yellow }
}

$console = Join-Path $GameLogDir 'console.log'
if (Test-Path $console) {
    $events = Get-Content $console -Tail 200 | Where-Object { $_ -match '\[(JOIN|LEAVE)\]' }
    $online = @{}
    foreach ($e in $events) { if ($e -match '\[(JOIN|LEAVE)\] (\S+)') { if ($Matches[1] -eq 'JOIN') { $online[$Matches[2]] = 1 } else { $online.Remove($Matches[2]) } } }
    Line 'Players' $(if ($online.Count) { ($online.Keys -join ', ') } else { 'none (since the last 200 log lines)' })
}

$latest = Get-ChildItem $SavesDir -Filter *.zip -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) { Line 'Newest save' "$($latest.Name), $($latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" }
$bk = Get-ChildItem $BackupDir -Filter *.zip -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if ($bk) { Line 'Backups' "$($bk.Count), newest $($bk[0].Name)" } else { Line 'Backups' 'none yet' Yellow }

$task = Get-ScheduledTask -TaskName 'Factorio Nightly Backup' -ErrorAction SilentlyContinue
if ($task) {
    $i = $task | Get-ScheduledTaskInfo
    $res = if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { "last $($i.LastRunTime.ToString('MM-dd HH:mm')) result $($i.LastTaskResult)" } else { 'not run yet' }
    Line 'Nightly' "$res, next $($i.NextRunTime.ToString('MM-dd HH:mm'))"
}
$fw = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
Line 'Firewall' $(if ($fw) { "'$FirewallRuleName' $(if ($fw.Enabled -eq 'True') { 'enabled' } else { 'DISABLED' })" } else { 'rule missing' }) $(if ($fw) { 'Gray' } else { 'Red' })
Write-Host ''
if (-not $NoPause) { Pause-IfInteractive }
