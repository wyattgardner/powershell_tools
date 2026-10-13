# Registers (or removes) the "Syncthing Monitor" scheduled task. Re-runnable.
#
#   install.cmd             register: hourly as SYSTEM, plus 15 minutes after boot
#   install.cmd -Uninstall  remove the task
#
# The task runs scripts\check.ps1 from this folder, so moving the folder means
# running install.cmd again.

param([switch]$Uninstall)

$scriptPath = $MyInvocation.MyCommand.Path
. (Join-Path $PSScriptRoot "_common.ps1")
if (-not (Test-Elevated)) {
    Write-Host "Not elevated. Relaunching with admin rights..."
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',
        "& '$($scriptPath -replace "'", "''")'$(if ($Uninstall) { ' -Uninstall' }); Read-Host 'Enter to close'")
    exit
}

$taskName = "Syncthing Monitor"
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed the '$taskName' task." -ForegroundColor Green
    } else { Write-Host "No '$taskName' task to remove." }
    return
}

$problems = @()
if (-not $AlertTo)  { $problems += "`$AlertTo isn't set in settings.ps1" }
if (-not $SmtpUser) { $problems += "`$SmtpUser isn't set in settings.ps1" }
if (-not (Test-Path $credFile)) { $problems += "no app password stored for $machine yet (run set-credential.cmd)" }
if ($problems) { $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; Write-Host "Fix those, then run install.cmd again."; return }

$check = Join-Path $PSScriptRoot "check.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"& '$($check -replace "'", "''")'`""

# Hourly: a daily trigger carrying the hourly repetition of a one-time trigger.
# (A one-time trigger alone needs an end date; this repeats forever.)
$hourly = New-ScheduledTaskTrigger -Daily -At "00:00"
$hourly.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 59)).Repetition
# After boot: catches a service that dies on startup (as Syncthing did every boot
# from May to October 2026) within minutes, not at the next hour.
$boot = New-ScheduledTaskTrigger -AtStartup
$boot.Delay = "PT15M"

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
# StartWhenAvailable: if the PC was off or asleep at a check, run it when it's back.
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($hourly, $boot) -Principal $principal -Settings $settings `
    -Description "Checks Syncthing, its devices and folders, and disk health; emails $AlertTo about problems. See $toolRoot." -Force | Out-Null
Write-Host "Registered '$taskName': hourly, and 15 minutes after boot, as SYSTEM." -ForegroundColor Green

# First run now, as SYSTEM, the way it will always run.
Start-ScheduledTask -TaskName $taskName
Write-Host "Started a first check. Results: $logFile"
