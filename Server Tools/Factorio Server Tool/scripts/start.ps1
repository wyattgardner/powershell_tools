# Starts the Factorio service and waits until it's hosting. Relaunches elevated.
param([switch]$NoPause)
. (Join-Path $PSScriptRoot '_common.ps1')
if (Invoke-Elevated $MyInvocation.MyCommand.Path) { exit }

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) { Write-Log 'Service not installed. Run install.cmd.' -Color Red; if (-not $NoPause) { Pause-IfInteractive }; exit 1 }
if ($svc.Status -eq 'Running') { Write-Host 'Already running.' -ForegroundColor Green; if (-not $NoPause) { Pause-IfInteractive }; exit 0 }

$since = Get-Date
Write-Log 'Starting service.'
Start-Service $ServiceName
if (Wait-Hosting -TimeoutSeconds 120 -Since $since) { Write-Log "Hosting on UDP $Port." -Color Green; $code = 0 }
else { Write-Log "Not in game after 120 s. Check $CurrentLog" -Color Red; $code = 1 }
if (-not $NoPause) { Pause-IfInteractive }
exit $code
