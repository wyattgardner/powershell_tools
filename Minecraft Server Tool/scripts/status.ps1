# One-screen answer to "is anything about to happen to the servers?"
#   - when the next maintenance reboot is, and whether Windows will reboot on its own
#   - pending Windows updates and which of them can force a reboot
#   - per server: running, players online, and whether a Spigot update is waiting
#   - BuildTools up to date
# No admin needed. Logs to status.log.

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolsDir "_lib.ps1")
New-Item -ItemType Directory $logDir -Force | Out-Null
Start-Transcript -Path (Join-Path $logDir "status.log") -Force | Out-Null

$now = Get-Date
Write-Host "Status as of $($now.ToString('ddd yyyy-MM-dd HH:mm'))" -ForegroundColor Cyan

# --- reboot schedule ---------------------------------------------------------------
Write-Host "`n== Reboots ==" -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("  Up since      : {0}  ({1})" -f $os.LastBootUpTime.ToString('ddd MMM d HH:mm'), (Format-Duration (($now - $os.LastBootUpTime).TotalMinutes)))

$task = Get-ScheduledTask -TaskName "Minecraft Daily Maintenance" -ErrorAction SilentlyContinue
if ($task) {
    $ti = $task | Get-ScheduledTaskInfo
    $next = $ti.NextRunTime
    Write-Host ("  Maintenance   : {0}  (in {1}), state {2}" -f $next.ToString('ddd MMM d HH:mm'), (Format-Duration (($next - $now).TotalMinutes)), $task.State)
    if ($ti.LastRunTime -and $ti.LastRunTime.Year -gt 2000) {
        Write-Host ("  Last run      : {0}, result 0x{1:X}" -f $ti.LastRunTime.ToString('ddd MMM d HH:mm'), $ti.LastTaskResult)
    }
} else {
    Write-Host "  Maintenance   : not found $(if ($MaintenanceEnabled) { '(or not visible: run status as admin to see SYSTEM tasks)' } else { '(off in settings)' })" -ForegroundColor Yellow
}
Write-Host ("  Settings      : Windows updates {0}, reboot {1}, restart servers daily {2}" -f $(if ($InstallWindowsUpdates) { 'installed by maintenance' } else { 'left to Windows' }), $RebootAfterMaintenance, $(if ($MaintenanceRestartServers) { 'yes' } else { 'no' }))

$au = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -ErrorAction SilentlyContinue
if ($au) {
    $days = @('every day','Sundays','Mondays','Tuesdays','Wednesdays','Thursdays','Fridays','Saturdays')
    $d = $days[[int]$au.ScheduledInstallDay]
    $mode = switch ([int]$au.AUOptions) { 2 {'notify only'} 3 {'download, notify to install'} 4 {"auto-install $d at {0:00}:00" -f $au.ScheduledInstallTime} 5 {'local admin chooses'} default {"AUOptions=$($au.AUOptions)"} }
    Write-Host "  Windows Update: $mode"
    if ([int]$au.ScheduledInstallDay -eq 0 -and [int]$au.AUOptions -eq 4) {
        Write-Host "                  (daily: Windows can reboot any morning, unannounced)" -ForegroundColor Yellow
    }
}

$flags = @()
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $flags += "servicing stack" }
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $flags += "Windows Update" }
try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { $flags += "WU agent" } } catch { }
# PendingFileRenameOperations is deliberately ignored: installers set it constantly
# and it doesn't mean Windows will reboot by itself.
if ($flags) { Write-Host ("  Reboot needed : YES ({0})" -f ($flags -join ', ')) -ForegroundColor Yellow }
else { Write-Host "  Reboot needed : no" }

# --- pending updates ------------------------------------------------------------------
Write-Host "`n== Pending Windows updates ==" -ForegroundColor Cyan
try {
    $r = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
    if ($r.Updates.Count -eq 0) { Write-Host "  none" }
    $mayReboot = 0
    foreach ($u in $r.Updates) {
        $rb = [int]$u.InstallationBehavior.RebootBehavior
        if ($rb -gt 0) { $mayReboot++ }
        $label = @('no reboot','REBOOTS','may reboot')[$rb]
        Write-Host ("  {0,-11} {1}{2}" -f $label, $u.Title, $(if ($u.IsDownloaded) { '' } else { '  (not downloaded)' }))
    }
    if ($r.Updates.Count -gt 0) {
        $when = if ($InstallWindowsUpdates) { "They install at the next maintenance window." } else { "Maintenance doesn't install them (`$InstallWindowsUpdates is off)." }
        Write-Host ("  -> {0} of {1} can require a reboot. {2}" -f $mayReboot, $r.Updates.Count, $when)
    }
} catch { Write-Host "  search failed: $($_.Exception.Message)" }

# --- servers ------------------------------------------------------------------------
Write-Host "`n== Servers ==" -ForegroundColor Cyan
$targets = @{}
foreach ($s in Get-AllServers) {
    $running = Test-ServiceRunning $s
    $cur = Get-RunningSpigotBuild $s
    $curMC = if ($cur) { $cur.MC } elseif ($s.JarName -match 'spigot-([\d.]+)\.jar') { $matches[1] } else { $null }
    $online = if ($running) { Get-OnlineCount $s } else { $null }
    $upd = "?"
    try {
        if (-not $targets.ContainsKey("$curMC")) { $targets["$curMC"] = Get-SpigotTarget $curMC }
        $t = $targets["$curMC"]
        if ($cur -and $cur.Build -eq $t.Build -and $cur.MC -eq $t.MC) { $upd = "up to date" }
        elseif ($t.MC -ne $curMC) { $upd = "MINECRAFT $curMC -> $($t.MC) available (needs confirm)" }
        else { $upd = "Spigot build $(if ($cur) { $cur.Build } else { '?' }) -> $($t.Build) available" }
        if (-not $t.SpigotHasLatest) { $upd += "  [Mojang has $($t.MojangLatest); Spigot hasn't published it]" }
    } catch { $upd = "couldn't check: $($_.Exception.Message)" }
    Write-Host ("  {0}" -f $s.Folder)
    Write-Host ("      service  : {0}{1}" -f $(if ($running) { 'running' } else { (Get-Service $s.ServiceName -ErrorAction SilentlyContinue).Status }), $(if ($null -ne $online) { ", $online online" } else { '' }))
    Write-Host ("      spigot   : {0}" -f $(if ($cur) { "build $($cur.Build), MC $($cur.MC)" } else { 'unknown' }))
    Write-Host ("      update   : {0}" -f $upd)
    foreach ($p in @(Get-PluginUpdates $s -NoDownload)) {
        $st = if ($p.Error) { "can't check: $($p.Error)" } elseif ($p.Needed -eq $true) { "UPDATE -> $($p.Remote.Label)" } elseif ($p.Needed -eq $false) { "current" } else { "unknown until first update" }
        Write-Host ("      plugin   : {0,-14} {1}" -f $p.Name, $st)
    }
}

# --- BuildTools --------------------------------------------------------------------
Write-Host "`n== BuildTools ==" -ForegroundColor Cyan
$l = Get-LocalBuildToolsNumber
try { $r = Get-RemoteBuildToolsNumber } catch { $r = $null }
Write-Host ("  local #{0}, latest #{1}{2}" -f $l, $r, $(if ($r -and $r -gt $l) { "  -> updates at the next maintenance or /update" } else { '' }))

Stop-Transcript | Out-Null
if ([Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() -match '^-NonI')) { Read-Host "`nEnter to close" | Out-Null }
