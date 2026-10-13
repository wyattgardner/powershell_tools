# Defaults for the Windows Settings Tool. Don't edit this file: it's replaced when the tool updates.
# To change an option, create config.psd1 next to it with just the options you want, e.g.
#   @{ Logging = $true }
# config.psd1 isn't tracked by git. Command-line switches override both files.
@{
    # Reopen in an admin window for Export and Import. Export needs admin to compare
    # against the Default user profile; Import needs it for machine-wide settings.
    # Diff never asks. Default: $true
    RunAsAdmin      = $true

    # Save a transcript of every run to Logs\ next to the script. Default: $false
    Logging         = $false

    # Where the backup goes. Relative paths are next to the script. Default: 'WinSettingsBackup'
    BackupPath      = 'WinSettingsBackup'

    # Import also applies the recorded items: service startup types, disabled scheduled
    # tasks, optional features, and other machine policies. Check DIFF.md first. Default: $false
    IncludeRecorded = $false

    # Import clears this PC's taskbar pins first, so the taskbar ends up exactly like the
    # backup's. Off keeps this PC's pins as they are and skips the backup's: Windows stores
    # the pins as one list, so the two can't be merged. Default: $true
    DeleteExistingPins = $true

    # Settings the old PC had at the Windows default (file extensions hidden, Sticky Keys shortcut
    # on, and so on) are normally left alone. On overwrites any of them changed on this PC, so it
    # matches the old PC. Does nothing on a fresh install, since those already match. Default: $false
    OverwriteChangedSettings = $false

    # Device defaults are ones Windows picks per PC: from screen size, manufacturer, or region, or
    # asked during setup (search box vs icon, Widgets, Num Lock, fast startup, startup sound, location,
    # diagnostic data). On copies the old PC's values. Off keeps this PC's own. Default: $true
    ApplyDeviceDefaults = $true

    # The PC's name on import. Needs admin; takes effect after the restart. Default: ''
    #   ''            leave this PC's name as it is
    #   'FromBackup'  use the old PC's name (Export always saves it)
    #   'GAMING-PC'   any other value is the name to set: 1-15 letters, digits or
    #                 hyphens, not only digits
    ComputerName    = ''
}
