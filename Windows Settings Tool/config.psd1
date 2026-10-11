# Windows Settings Tool options. Command-line switches override these.
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
