# Monitor settings.
#
# To change them: copy settings.defaults.ps1 to settings.ps1 and edit the copy, or
# put just the lines you change in settings.ps1. Defaults load first, then
# settings.ps1. settings.ps1 is gitignored, so your addresses are never committed.

# --- Email ---------------------------------------------------------------------------

# Who gets the alerts. Required.
$AlertTo = ""

# The Gmail account that sends them. Its app password is stored separately, encrypted,
# by set-credential.cmd. Required.
$SmtpUser   = ""
$SmtpServer = "smtp.gmail.com"
$SmtpPort   = 587

# --- What counts as a problem -----------------------------------------------------------

# A remote device that hasn't connected for this long.
$DeviceUnseenHours = 24

# A folder that has stayed out of sync (this PC needs files, or a connected device is
# below 100%) for this long, or a folder or device left paused this long. Short gaps
# are normal while syncing.
$OutOfSyncHours = 24

# Disk and file system errors in the Windows event log (disk, NTFS, storage drivers,
# WHEA hardware errors), plus any physical disk Windows doesn't report as Healthy.
# A failing disk under a synced folder can sync damage to every other device.
$CheckDiskErrors = $true

# Event providers counted as disk errors. Errors and warnings only.
$DiskEventProviders = @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'stornvme', 'storahci', 'nvme', 'iaStorA', 'iaStorAC', 'iaStorAVC', 'partmgr', 'Microsoft-Windows-WHEA-Logger')

# --- When it emails ------------------------------------------------------------------------

# A new problem is emailed at once. While it lasts, one reminder a day, at the first
# check at or after this hour (24h clock). A "recovered" email is sent when it clears.
$ReminderHour = 16

# Weekly "all good" email, so silence never goes unnoticed: if these stop arriving,
# the monitor itself is broken. Sent at the first check at or after this day and
# hour. $HeartbeatDay = "" turns it off.
$HeartbeatDay  = "Saturday"
$HeartbeatHour = 16

# --- Syncthing -----------------------------------------------------------------------------

# Empty = find it: the Windows service running syncthing.exe, and its --home folder.
# Set them if Syncthing runs some other way.
$SyncthingService = ""
$SyncthingHome    = ""
