# Stops the Factorio service: NSSM sends Ctrl+C, Factorio saves and exits, then the save
# is backed up. It stays stopped until start.cmd or the next boot. Relaunches elevated.
param([switch]$NoPause, [string]$Reason = 'stop')
. (Join-Path $PSScriptRoot '_common.ps1')
if (Invoke-Elevated $MyInvocation.MyCommand.Path) { exit }

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -eq 'Stopped') {
    Write-Host 'Not running.'
} else {
    Write-Log "Stopping service ($Reason). Factorio saves on the way out."
    Stop-Service $ServiceName
    $saved = (Test-Path $CurrentLog) -and (Select-String -Path $CurrentLog -Pattern 'Saving progress: 100' -Quiet)
    if ($saved) { Write-Log 'Stopped. Map saved.' -Color Green }
    else { Write-Log "Stopped, but no save line in factorio-current.log. Check it." -Color Yellow }
    Start-Sleep -Seconds 16      # Backup-Saves skips files younger than 15 s
    Backup-Saves $Reason | Out-Null
}
if (-not $NoPause) { Pause-IfInteractive }
