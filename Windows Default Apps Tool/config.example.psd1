# Defaults for the Windows Default Apps Tool. Don't edit this file: it's replaced when the tool updates.
# To change an option, create config.psd1 next to it with just the options you want, e.g.
#   @{ Logging = $true }
# config.psd1 isn't tracked by git. Command-line switches override both files.
@{
    # How Import applies your default apps. Default: 'Auto'
    #   'Auto'    Policy on domain-joined PCs, Direct everywhere else
    #   'Direct'  writes them straight to the registry. Only works where UserChoiceLatest is off (see the README),
    #             and never for http, https, or .pdf. Hands anything it can't set over to Guided
    #   'Guided'  opens each app's Default apps page in Settings and checks the types off as you set them
    #   'Policy'  a Windows policy applies them at your next sign-in. Needs admin, and Windows only honors it
    #             for existing accounts on domain-joined PCs (elsewhere it only affects new accounts)
    ImportMethod = 'Auto'

    # Reopen in an admin window when Import uses the Policy method.
    # Guided, Export, and Preview never ask. Default: $true
    RunAsAdmin  = $true

    # Save a transcript of every run to Logs\ next to the script. Default: $false
    Logging     = $false

    # Where the backup goes. Relative paths are next to the script. Default: 'DefaultAppsBackup'
    BackupPath  = 'DefaultAppsBackup'

    # Apply only your exact choices. When $false, an app that replaced a Windows default
    # (Chrome over Edge, VLC over Media Player) also takes over the other types it supports
    # that the replaced app would open. Default: $false
    OnlyMine    = $false

    # Import without asking to start first. Default: $false
    SkipConfirm = $false
}
