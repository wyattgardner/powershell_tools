# One-time setup (re-runnable) for updates and maintenance. RUN ELEVATED.
# Everything it does follows settings.ps1 (defaults in settings.defaults.ps1), and
# re-running it after changing a setting brings the machine in line.
#
#   1. per server: update.cmd launcher
#   2. $InGameUpdateCommand: builds ServerToolUpdater; per server a
#      "Minecraft Update - <server>" scheduled task + the plugin jar and its config
#   3. $MaintenanceEnabled: "Minecraft Daily Maintenance" scheduled task
#   4. $ManageWindowsUpdatePolicy: Windows Update set to download only, never
#      install or reboot on its own
#
# The plugin loads the next time each server restarts. Logs to install-automation.log.

param(
    [string]$MaintenanceDay,    # override settings for this run
    [string]$MaintenanceTime,
    [switch]$NoPause            # don't wait for Enter at the end (for scripted runs)
)
$argDay = $MaintenanceDay; $argTime = $MaintenanceTime

$scriptPath = $MyInvocation.MyCommand.Path
$toolsDir = Split-Path -Parent $scriptPath

# Relaunch elevated with -Command (not -File, which mangles paths with spaces).
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not elevated. Relaunching with admin rights..."
    $cmd = "& '$($scriptPath -replace "'", "''")'"
    if ($argDay)  { $cmd += " -MaintenanceDay '$argDay'" }
    if ($argTime) { $cmd += " -MaintenanceTime '$argTime'" }
    if ($NoPause) { $cmd += " -NoPause" }
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $cmd)
    exit
}

. (Join-Path $toolsDir "_lib.ps1")    # loads settings, which would overwrite the params
if ($argDay)  { $MaintenanceDay  = $argDay }
if ($argTime) { $MaintenanceTime = $argTime }
New-Item -ItemType Directory $logDir -Force | Out-Null
Start-Transcript -Path (Join-Path $logDir "install-automation.log") -Force | Out-Null

function Step($label, $block) {
    try { & $block; Write-Host "  OK   $label" -ForegroundColor Green; return $true }
    catch { Write-Host "  FAIL $label" -ForegroundColor Red; Write-Host "       $($_.Exception.Message)" -ForegroundColor Red; return $false }
}
function Quit($code) { Stop-Transcript | Out-Null; if ([Environment]::UserInteractive -and -not $NoPause) { Read-Host "Enter to close" | Out-Null }; exit $code }

$system  = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$servers = @(Get-AllServers)
if (-not $servers) { Write-Host "No servers yet. Run install.cmd first." -ForegroundColor Yellow }

# --- 1. plugin build ----------------------------------------------------------------
$pluginJar = Join-Path $toolRoot "plugin\build\ServerToolUpdater.jar"
$pluginOk = $false
if ($InGameUpdateCommand) {
    Write-Host "`n=== /update plugin ===" -ForegroundColor Cyan
    & (Join-Path $toolRoot "plugin\build-plugin.ps1")
    $pluginOk = ($LASTEXITCODE -eq 0 -and (Test-Path $pluginJar))
    if (-not $pluginOk) {
        Write-Host "  Plugin build failed (see plugin\build-plugin.log). Carrying on without /update;" -ForegroundColor Yellow
        Write-Host "  usually it just needs one BuildTools run first. Run update.cmd, then re-run this." -ForegroundColor Yellow
    }
}

# --- 2. per server ----------------------------------------------------------------------
Write-Host "`n=== Servers ===" -ForegroundColor Cyan
foreach ($s in $servers) {
    Write-Host "  [$($s.Folder)]"
    $srvTools = Join-Path $serversDir $s.Folder
    # Launchers from _template, so fixes to them reach existing servers. Never server.config.ps1.
    Step "launchers" {
        Get-ChildItem (Join-Path $toolRoot "_template") -File | Where-Object { $_.Name -notin 'server.config.ps1','log4j2.xml' } |
            Copy-Item -Destination $srvTools -Force -ErrorAction Stop
    } | Out-Null

    $taskName = "Minecraft Update - $($s.Folder)"
    $plugins  = Join-Path $s.ServerDir "plugins"
    $pcfgDir  = Join-Path $plugins "ServerToolUpdater"

    if (-not $InGameUpdateCommand) {
        # Turned off: take it all back out.
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Step "remove task '$taskName'" { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop } | Out-Null
        }
        $jar = Join-Path $plugins "ServerToolUpdater.jar"
        if (Test-Path $jar) { Step "remove plugin jar (takes effect on restart)" { Remove-Item $jar -Force -ErrorAction Stop } | Out-Null }
        continue
    }
    if (-not $pluginOk) { continue }

    $q = $s.Folder -replace "'", "''"
    # -RequireConfirm: /update is the one path that asks before a Minecraft version jump.
    $cmd = "& '$($toolsDir -replace "'", "''")\update-spigot.ps1' -Server '$q' -RequireConfirm"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Step "task '$taskName'" {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $system -Settings $settings `
            -Description "Run by /update (ServerToolUpdater) for $($s.Folder). No trigger: on demand only." -Force -ErrorAction Stop | Out-Null
    } | Out-Null

    Step "plugin jar -> $plugins" {
        New-Item -ItemType Directory $plugins -Force | Out-Null
        Copy-Item $pluginJar (Join-Path $plugins "ServerToolUpdater.jar") -Force -ErrorAction Stop
    } | Out-Null
    Step "plugin config (task-name)" {
        New-Item -ItemType Directory $pcfgDir -Force | Out-Null
        @(
            "# Written by install-automation.ps1. The scheduled task /update runs for this server."
            "task-name: `"$taskName`""
            "cooldown-seconds: 60"
        ) | Set-Content (Join-Path $pcfgDir "config.yml") -Encoding utf8 -ErrorAction Stop
    } | Out-Null
}

# --- 3. maintenance ---------------------------------------------------------------
$mName = "Minecraft Daily Maintenance"
if ($MaintenanceEnabled) {
    Write-Host "`n=== Maintenance ($MaintenanceDay $MaintenanceTime) ===" -ForegroundColor Cyan
    $mCmd = "& '$($toolsDir -replace "'", "''")\maintenance.ps1'"
    $mAction  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$mCmd`""
    $mTrigger = if ($MaintenanceDay -eq 'Daily') { New-ScheduledTaskTrigger -Daily -At $MaintenanceTime }
                else { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $MaintenanceDay -At $MaintenanceTime }
    # StartWhenAvailable off on purpose: if the PC was off at maintenance time, don't run a
    # countdown and restart at some random point in the afternoon instead.
    $mSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $mSettings.StartWhenAvailable = $false
    Step "task '$mName' ($MaintenanceDay $MaintenanceTime)" {
        Register-ScheduledTask -TaskName $mName -Action $mAction -Trigger $mTrigger -Principal $system -Settings $mSettings `
            -Description "Updates servers (Spigot, plugins, BuildTools), warns players, restarts. See maintenance.ps1 and settings." -Force -ErrorAction Stop | Out-Null
    } | Out-Null
} else {
    Write-Host "`n=== Maintenance: off in settings ===" -ForegroundColor Cyan
    if (Get-ScheduledTask -TaskName $mName -ErrorAction SilentlyContinue) {
        Step "remove task '$mName'" { Unregister-ScheduledTask -TaskName $mName -Confirm:$false -ErrorAction Stop } | Out-Null
    }
}

# --- 4. Windows Update: download only, never install on its own -----------------------
# With this on, maintenance is the ONE time anything installs or reboots. Windows is set
# to AUOptions=3 ("download automatically, notify to install"): it keeps downloading in
# the background, so maintenance's install is quick, but never installs or reboots by
# itself. Letting Windows install on its own schedule too (AUOptions=4) would risk an
# unannounced reboot in the middle of a players' countdown.
# Tradeoff: if the maintenance task breaks, updates stop going in. status.ps1 shows
# the task's last result.
#
# The setting lives in the local GPO's Registry.pol, not just the registry: writing
# the registry value alone gets reverted on the next policy refresh. It's a DWORD,
# so it can be patched in place without changing the file's structure.
if ($ManageWindowsUpdatePolicy) {
    Write-Host "`n=== Windows Update: download only ===" -ForegroundColor Cyan
    if (-not $InstallWindowsUpdates) {
        Write-Host "  WARNING: `$InstallWindowsUpdates is off, so with this policy updates would never install." -ForegroundColor Yellow
        Write-Host "  Turn one on or the other off in settings.ps1. Skipping the policy." -ForegroundColor Yellow
    } else {
        $wantAU = 3
        $pol = "C:\Windows\System32\GroupPolicy\Machine\Registry.pol"
        $bak = "$pol.$(Get-Date -Format yyyyMMdd-HHmmss).bak"

        # Patch one DWORD value in Registry.pol in place.
        # Entry layout (UTF-16LE): [key;value;type;size;data] with type/size/data as raw bytes.
        function Set-PolDword([byte[]]$bytes, [string]$name, [uint32]$value) {
            $needle = [Text.Encoding]::Unicode.GetBytes("$name`0;")
            for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
                $ok = $true
                for ($j = 0; $j -lt $needle.Length; $j++) { if ($bytes[$i + $j] -ne $needle[$j]) { $ok = $false; break } }
                if (-not $ok) { continue }
                $p = $i + $needle.Length
                $type = [BitConverter]::ToUInt32($bytes, $p)
                $size = [BitConverter]::ToUInt32($bytes, $p + 6)     # 4 bytes type + 2 bytes ';'
                $dataAt = $p + 12                                     # + 4 bytes size + 2 bytes ';'
                if ($type -ne 4 -or $size -ne 4) { Write-Host "  $name has unexpected format (type $type size $size)" -ForegroundColor Yellow; return $false }
                $old = [BitConverter]::ToUInt32($bytes, $dataAt)
                [BitConverter]::GetBytes($value).CopyTo($bytes, $dataAt)
                Write-Host "  Registry.pol ${name}: $old -> $value"
                return $true
            }
            Write-Host "  $name not in Registry.pol" -ForegroundColor Yellow
            return $false
        }

        $patched = $false
        if (Test-Path $pol) {
            Copy-Item $pol $bak
            Write-Host "  backup: $bak"
            $bytes = [IO.File]::ReadAllBytes($pol)
            if (Set-PolDword $bytes "AUOptions" $wantAU) { [IO.File]::WriteAllBytes($pol, $bytes); $patched = $true }
        }
        if (-not $patched) {
            # Registry.pol only has the value once the policy has been set in gpedit at least once.
            Write-Host "  Set it by hand once: gpedit > Computer Configuration > Administrative Templates > Windows Components >" -ForegroundColor Yellow
            Write-Host "  Windows Update > (Manage end user experience >) Configure Automatic Updates > Enabled, 3 - Auto download and notify for install" -ForegroundColor Yellow
        }
        & gpupdate /target:computer /force | Out-Null
        $au = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -ErrorAction SilentlyContinue
        Write-Host ("  effective: AUOptions={0} (3 = download, never auto-install)" -f $au.AUOptions)
        if ($patched -and [int]$au.AUOptions -ne $wantAU) {
            Write-Host "  WARNING: policy did not take. Restoring backup." -ForegroundColor Red
            if (Test-Path $bak) { Copy-Item $bak $pol -Force; & gpupdate /target:computer /force | Out-Null }
        }
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Get-ScheduledTask -TaskName "Minecraft*" -ErrorAction SilentlyContinue | ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo
    $n = if ($i.NextRunTime) { $i.NextRunTime.ToString('ddd MMM d HH:mm') } else { 'on demand' }
    Write-Host ("  {0,-48} next: {1}" -f $_.TaskName, $n)
}
Write-Host ("  Windows updates: {0}; reboot after maintenance: {1}" -f $(if ($InstallWindowsUpdates) { 'installed by maintenance' } else { 'left to Windows' }), $RebootAfterMaintenance)
if ($pluginOk) { Write-Host "`nThe /update plugin loads on each server's next restart." -ForegroundColor Green }
Write-Host "Log: $(Join-Path $logDir 'install-automation.log')"
Quit 0
