# Updates the game with steamcmd. RUN ELEVATED (relaunches itself).
#   1. stop the service (Ctrl+C: saves) and back up the save
#   2. steamcmd app_update (saves, mods, config and the server\ files aren't touched)
#   3. put config-path.cfg back (steamcmd's validate restores Steam's AppData version)
#   4. show the old and new version, start the service
# Every player's client must be on the same version as the server afterwards.
param([switch]$NoPause)
. (Join-Path $PSScriptRoot '_common.ps1')
if (Invoke-Elevated $MyInvocation.MyCommand.Path) { exit }
$log = 'update.log'

$old = Get-FactorioVersion
Write-Log "Update starting. Current version: $old" $log
if (-not $SteamUser) { Write-Log 'Set $SteamUser in settings.ps1 first.' $log Red; Pause-IfInteractive; exit 1 }
if (-not (Test-Path $SteamCmd)) { Write-Log "steamcmd not found at $SteamCmd" $log Red; Pause-IfInteractive; exit 1 }

& (Join-Path $PSScriptRoot 'stop.ps1') -NoPause -Reason 'pre-update'
if ((Get-Service $ServiceName).Status -ne 'Stopped') { Write-Log 'Service did not stop. Not updating.' $log Red; Pause-IfInteractive; exit 1 }

Write-Log "Running steamcmd as $SteamUser. If it asks for a password or Steam Guard code, type it here." $log
& $SteamCmd +force_install_dir $GameDir +login $SteamUser +app_update $SteamAppId validate +quit
$steamExit = $LASTEXITCODE
Write-Log "steamcmd exit code $steamExit" $log

if (Set-ConfigPath) { Write-Log 'config-path.cfg was reset by steamcmd; put back.' $log }
Set-ModList
$new = Get-FactorioVersion
if ($new -eq $old) { Write-Log "Version unchanged: $new" $log Yellow }
else { Write-Log "Updated $old -> $new. Everyone's client must be on $new to join." $log Green }

& (Join-Path $PSScriptRoot 'start.ps1') -NoPause
if (-not $NoPause) { Pause-IfInteractive }
