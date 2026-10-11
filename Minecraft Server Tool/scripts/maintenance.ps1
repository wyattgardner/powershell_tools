param(
    [int[]]$WarnAt,                 # minutes before restart to warn players (default: settings)
    [switch]$NoServerUpdates,       # skip Spigot / plugin / BuildTools updates
    [switch]$NoReboot,              # never reboot this run, whatever settings say
    [switch]$DryRun                 # report only: prints messages instead of sending, changes nothing
)

# Maintenance window. Runs as SYSTEM from the "Minecraft Daily Maintenance"
# scheduled task (time and day set in settings, registered by install-automation.ps1).
#
#   1. while servers are still up: update BuildTools, build Spigot, download plugins
#      (update-spigot.ps1 -BuildOnly, cached so servers share one build)
#   2. warn players on every running server (skipped if nobody's on)
#   3. apply staged server updates: per server, ONE stop -> backup -> swap -> start
#      -> verify (-> roll back if it didn't come up)
#   4. save and stop every server
#   5. install pending Windows updates          ($InstallWindowsUpdates, off by default)
#   6. reboot, or start the servers back up    ($RebootAfterMaintenance, "Never" by default)
#
# If there's nothing to update and $MaintenanceRestartServers is off, it stops
# after step 1 and nobody gets kicked.
#
# Servers set to Automatic start are included even if they happen to be stopped,
# since they'd be running after a reboot anyway. Manual-start ones are left alone.

$scriptPath = $MyInvocation.MyCommand.Path
$toolsDir   = Split-Path -Parent $scriptPath
. (Join-Path $toolsDir "_lib.ps1")
$updater = Join-Path $toolsDir "update-spigot.ps1"
if (-not $WarnAt) { $WarnAt = $MaintenanceWarnMinutes }
if (-not $UpdateSpigot -and -not $UpdatePlugins) { $NoServerUpdates = $true }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Host "Not elevated. Relaunching with admin rights..."
    $cmd = "& '$($scriptPath -replace "'", "''")'"
    if ($NoServerUpdates) { $cmd += " -NoServerUpdates" }
    if ($NoReboot)        { $cmd += " -NoReboot" }
    if ($PSBoundParameters.ContainsKey('WarnAt')) { $cmd += " -WarnAt " + ($WarnAt -join ',') }
    # -NoExit keeps the window up afterwards so the result can be read.
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-Command',$cmd)
    exit
}

New-Item -ItemType Directory $logDir -Force | Out-Null
$logFile = Join-Path $logDir "maintenance.log"
Start-Transcript -Path $logFile -Append | Out-Null
$t0 = Get-Date
Write-Host "`n=== Maintenance started $($t0.ToString('yyyy-MM-dd HH:mm:ss'))$(if ($DryRun) { ' (DRY RUN)' }) ==="

$auto = @(Get-AllServers | Where-Object { (Get-CimInstance Win32_Service -Filter "Name='$($_.ServiceName)'" -ErrorAction SilentlyContinue).StartMode -eq 'Auto' })
$running = @($auto | Where-Object { Test-ServiceRunning $_ })
Write-Host ("Servers (auto-start): {0}" -f $(if ($auto) { ($auto | ForEach-Object { "$($_.Folder)$(if (Test-ServiceRunning $_) { '' } else { ' [stopped]' })" }) -join ', ' } else { 'none' }))

# Dry runs print instead of broadcasting: a fake "going down in 15 minutes" to real
# players is worse than no test at all.
function SayAll($msg) {
    if ($DryRun) { Write-Host "    would say: [Maintenance] $msg"; return }
    foreach ($s in $running) { Send-Say $s "[Maintenance] $msg" }
}

# --- 1. Windows updates pending --------------------------------------------------
$session = $null
$pending = $null
if ($InstallWindowsUpdates) {
    Write-Host "`n--- Pending Windows updates ---"
    $session = New-Object -ComObject Microsoft.Update.Session
    try {
        $pending = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0").Updates
        Write-Host "  $($pending.Count) pending"
        foreach ($u in $pending) {
            Write-Host ("    [{0}] {1}" -f @('never reboots','always reboots','may reboot')[$u.InstallationBehavior.RebootBehavior], $u.Title)
        }
    } catch { Write-Host "  update search failed: $($_.Exception.Message)" }
}

# --- 2. stage server updates (servers still up) ---------------------------------------
$staged = @()
if (-not $NoServerUpdates) {
    Write-Host "`n--- Server updates: build / download ---"
    foreach ($s in $auto) {
        $opts = @{ Server = $s.Folder; Quiet = $true }
        if ($DryRun) { $opts.CheckOnly = $true } else { $opts.BuildOnly = $true }
        & $updater @opts | Out-Null
        $code = $LASTEXITCODE
        $msg = switch ($code) { 0 { if ($DryRun) { 'see update.log (check only)' } else { 'already current' } } 3 { 'staged' } 1 { 'FAILED (see update.log)' } default { "exit $code" } }
        Write-Host ("  {0}: {1}" -f $s.Folder, $msg)
        if ($code -eq 3) { $staged += $s }
    }
}

# --- 3. countdown -------------------------------------------------------------------
$haveWinUpdates = ($pending -and $pending.Count -gt 0)
if (-not $staged -and -not $haveWinUpdates -and -not $MaintenanceRestartServers -and $RebootAfterMaintenance -ne 'Always') {
    Write-Host "`nNothing to update and daily restarts are off. Leaving the servers running."
    Write-Host ("=== Maintenance finished in {0:N0} min ===" -f ((Get-Date) - $t0).TotalMinutes)
    Stop-Transcript | Out-Null; exit 0
}
$willReboot = (-not $NoReboot) -and ($RebootAfterMaintenance -eq 'Always' -or ($RebootAfterMaintenance -eq 'IfRequired' -and $haveWinUpdates))
$backIn = if ($willReboot) { "about 10 minutes" } else { "a couple of minutes" }
$total = 0
foreach ($s in $running) { $n = Get-OnlineCount $s; if ($n) { $total += $n } }
$parts = @()
if ($haveWinUpdates) { $parts += "Windows updates" }
if ($staged) { $parts += "server updates" }
$why = if ($parts) { ($parts -join ' and ') + " and a restart" } else { "a scheduled restart" }
Write-Host "`n--- Countdown ($total online; reason: $why) ---"
if ($total -gt 0) {
    $marks = $WarnAt | Sort-Object -Descending
    for ($i = 0; $i -lt $marks.Count; $i++) {
        $m = $marks[$i]
        SayAll "Server goes down in $m $(if ($m -eq 1) { 'minute' } else { 'minutes' }) for $why. Back in $backIn."
        Write-Host "  T-$m min announced"
        $next = if ($i + 1 -lt $marks.Count) { $marks[$i + 1] } else { 0 }
        if (-not $DryRun) { Start-Sleep -Seconds (($m - $next) * 60) }
    }
    SayAll "Going down now. See you in $backIn."
} else {
    Write-Host "  nobody online; no countdown"
}

if ($DryRun) {
    Write-Host "`nDry run: stopping here."
    Stop-Transcript | Out-Null; exit 0
}

# --- 4. apply staged server updates ------------------------------------------------------
# One stop/start per server. update-spigot backs up, swaps, starts, verifies, and
# rolls back on its own if the server doesn't come up right.
foreach ($s in $staged) {
    Write-Host "`n--- Applying updates: $($s.Folder) ---"
    & $updater -Server $s.Folder -Quiet -CountdownSeconds 0 | Out-Null
    Write-Host ("  result: {0}" -f $(switch ($LASTEXITCODE) { 0 { 'updated' } 1 { 'FAILED or rolled back (see its update.log)' } default { "exit $LASTEXITCODE" } }))
}

# --- 5. stop every server (saves first) -----------------------------------------------
Write-Host "`n--- Stopping servers ---"
foreach ($s in $auto) {
    if (Test-ServiceRunning $s) { & (Join-Path $toolsDir "shutdown-minecraft.ps1") -Server $s.Folder }
    Write-Host ("  {0}: {1}" -f $s.Folder, (Get-Service $s.ServiceName).Status)
}

# --- 6. install Windows updates ----------------------------------------------------------
if (-not $InstallWindowsUpdates) {
    Write-Host "`n--- Windows updates: skipped (`$InstallWindowsUpdates is off) ---"
} elseif ($haveWinUpdates) {
    Write-Host "`n--- Installing Windows updates ---"
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $pending) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) }
    try {
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
        Write-Host "  download result: $($dl.Download().ResultCode) (2 = succeeded)"
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $ir = $inst.Install()
        Write-Host "  install result : $($ir.ResultCode) (2 = succeeded, 3 = succeeded with errors)"
        for ($i = 0; $i -lt $coll.Count; $i++) {
            Write-Host ("    [{0}] {1}" -f $ir.GetUpdateResult($i).ResultCode, $coll.Item($i).Title)
        }
    } catch { Write-Host "  install failed: $($_.Exception.Message)" -ForegroundColor Red }
} else {
    Write-Host "`n--- Windows updates: nothing to install ---"
}

# --- 7. reboot, or start back up ---------------------------------------------------------
# IfRequired asks Windows after the install, not before: an update that said "may
# reboot" often doesn't need one.
if (-not $NoReboot -and $RebootAfterMaintenance -eq 'IfRequired') {
    $needs = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") -or
             (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
    try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { $needs = $true } } catch { }
    $willReboot = $needs
    Write-Host "`nReboot required by Windows: $(if ($needs) { 'yes' } else { 'no' })"
}
if (-not $willReboot) {
    Write-Host "`nNo reboot: starting the servers back up."
    foreach ($s in $auto) { & (Join-Path $toolsDir "start-minecraft.ps1") -Server $s.Folder }
    Write-Host ("=== Maintenance finished in {0:N0} min ===" -f ((Get-Date) - $t0).TotalMinutes)
    Stop-Transcript | Out-Null; exit 0
}

Write-Host "`n--- Rebooting in 30s ---"
Write-Host ("=== Maintenance finished in {0:N0} min (rebooting) {1} ===" -f ((Get-Date) - $t0).TotalMinutes, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Stop-Transcript | Out-Null
& shutdown.exe /r /t 30 /c "Minecraft maintenance" /d p:0:0
