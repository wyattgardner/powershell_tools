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
}
