# Default settings. Don't edit this file: copy the lines you want to change into
# settings.ps1 next to it (gitignored), which is loaded after this one.

# Game install from steamcmd. Saves, mods, config and Factorio's own logs live here too
# (config-path.cfg points Factorio's write-data folder at this folder).
$GameDir     = 'C:\Servers\Factorio Server'

# Windows service (NSSM) and network
$ServiceName = 'factorio'
$DisplayName = 'Factorio Server'
$Port        = 34197                       # UDP. The router forwards this to Pantheon.
$FirewallRuleName = 'Factorio UDP 34197'

# Seconds NSSM waits after factorio.exe exits before starting it again
$RestartDelaySeconds = 10

# Updates (update.cmd). Factorio isn't an anonymous steamcmd download, so this account
# must own Factorio and have logged in to steamcmd once with "remember password".
$SteamCmd    = 'C:\Servers\steamcmd\steamcmd.exe'
$SteamUser   = ''                          # set in settings.ps1
$SteamAppId  = 427520

# Backups: the newest save is copied to server\backups on every stop and nightly.
# server\ is inside the Syncthing-synced Projects folder, so backups reach the other PC.
$NightlyBackup     = $true
$NightlyBackupTime = '03:30'               # before the 04:00 Minecraft maintenance reboot
$BackupKeep        = 30                    # newest N backups kept, older ones deleted

# NSSM 2.24-101: same pinned build and hash as the Minecraft Server Tool
$NssmUrl    = 'https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip'
$NssmEntry  = 'nssm-2.24-101-g897c7ad/win64/nssm.exe'
$NssmSha256 = 'EEE9C44C29C2BE011F1F1E43BB8C3FCA888CB81053022EC5A0060035DE16D848'
