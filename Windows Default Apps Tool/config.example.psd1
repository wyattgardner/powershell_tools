# Defaults for the Windows Default Apps Tool. Don't edit this file: it's replaced when the tool updates.
# To change an option, create config.psd1 next to it with just the options you want, e.g.
#   @{ Logging = $true }
# config.psd1 isn't tracked by git. Command-line switches override both files.
@{
    # Reopen in an admin window for Import, which uses a Windows policy.
    # Export and Preview never ask. Default: $true
    RunAsAdmin  = $true

    # Save a transcript of every run to Logs\ next to the script. Default: $false
    Logging     = $false

    # Where the backup goes. Relative paths are next to the script. Default: 'DefaultAppsBackup'
    BackupPath  = 'DefaultAppsBackup'

    # Apply only your exact choices. When $false, an app that replaced a Windows default
    # (Chrome over Edge, VLC over Media Player) also takes over the other types it supports
    # that the replaced app would open. Default: $false
    OnlyMine    = $false

    # Import without asking "Apply these default apps? (Y/N)" first. Default: $false
    SkipConfirm = $false
}
