# Copies the newest save to server\backups. Run by the nightly task, or by hand
# (backup.cmd). Safe while the server runs: it skips a save written in the last 15 s.
param([string]$Reason = 'manual', [switch]$NoPause)
. (Join-Path $PSScriptRoot '_common.ps1')
$dest = Backup-Saves $Reason
if (-not $NoPause -and $Reason -eq 'manual') { Pause-IfInteractive }
if ($dest) { exit 0 } else { exit 1 }
