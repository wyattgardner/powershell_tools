<#
  WindowsSettings.ps1 - bring a fresh Windows 11 install up to speed with your settings.

  Modes:
    Export  Save only the settings you've changed from Windows defaults into WinSettingsBackup, plus CHANGES.md.
            Run as admin (Run-Export.bat does this) so it can compare against the Default user profile.
    Import  Apply a backup to this PC. Run as admin to also apply machine-wide settings.
            Add -IncludeRecorded to also apply services, scheduled tasks, optional features, and other machine policies.
            -ComputerName renames the PC: 'FromBackup' for the old PC's name, or the name to use. Off by default.
    Diff    Read-only. Compare a backup with this PC's current settings and write DIFF.md next to this script.

  Normally run through Run-Export.bat, Run-Import.bat, and Run-Diff.bat.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import', 'Diff')][string]$Mode,
    [string]$Path,
    [switch]$IncludeRecorded,
    [string]$ComputerName,   # Import: '' leaves the PC name alone, 'FromBackup' uses the old PC's, anything else is the new name
    [switch]$Log,
    [switch]$Elevated,   # set when the script reopened itself as admin
    [switch]$AutoClose   # count down 5 seconds at the end (P pauses); the .bat files pass this
)

try {
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Options: defaults from config.example.psd1, then your overrides from config.psd1 (not tracked by git).
# Both are read as data, never run. Command-line switches override both.
$Config = @{}
foreach ($name in 'config.example.psd1', 'config.psd1') {
    $file = Join-Path $ScriptDir $name
    if (-not (Test-Path $file)) { continue }
    try { $c = Import-PowerShellDataFile $file; foreach ($k in $c.Keys) { $Config[$k] = $c[$k] } }
    catch { Write-Warning "Couldn't read $name, skipping it: $($_.Exception.Message)" }
}
function Get-ConfigBool($name, $default) { if ($Config.ContainsKey($name)) { [bool]$Config[$name] } else { $default } }
if (-not $Path -and $Config.BackupPath) {
    $Path = [Environment]::ExpandEnvironmentVariables($Config.BackupPath)
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $ScriptDir $Path }
}
if (-not $PSBoundParameters.ContainsKey('IncludeRecorded')) { $IncludeRecorded = Get-ConfigBool 'IncludeRecorded' $false }
# PC name on import. Off by default: '' leaves it alone. 'FromBackup' uses the name Export
# saved in meta.json; anything else is the name to set.
if (-not $PSBoundParameters.ContainsKey('ComputerName')) { $ComputerName = [string]$Config.ComputerName }
$ComputerName = "$ComputerName".Trim()
function Get-TargetName($meta) {
    if (-not $ComputerName) { return $null }
    if ($ComputerName -eq 'FromBackup') { return "$($meta.Computer)".Trim() }
    return $ComputerName
}
# Windows' rules: 1-15 characters, letters, digits and hyphens, not only digits, no hyphen at either end.
function Test-PcName($n) { $n -match '^(?!-)(?!\d+$)[A-Za-z0-9-]{1,15}(?<!-)$' }
# RunAsAdmin (on by default): reopen this script in an admin window when the mode needs it. Exit code 99 tells the .bat it moved on.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Mode -in 'Export', 'Import') -and -not $IsAdmin -and -not $Elevated -and (Get-ConfigBool 'RunAsAdmin' $true)) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"", '-Elevated')
    foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch]) { if ($p.Value.IsPresent) { $a += "-$($p.Key)" } } else { $a += "-$($p.Key)", "`"$($p.Value)`"" }
    }
    try { Start-Process powershell -Verb RunAs -ArgumentList $a; Write-Host 'Continuing in an admin window...'; $script:Relaunched = $true; exit 99 }
    catch { Write-Warning 'The admin prompt was declined, so this runs without admin.' }
}$Logging = if ($PSBoundParameters.ContainsKey('Log')) { [bool]$Log } else { Get-ConfigBool 'Logging' $false }
if ($Logging) {
    New-Item -ItemType Directory -Force (Join-Path $ScriptDir 'Logs') | Out-Null
    try { Start-Transcript -Path (Join-Path $ScriptDir "Logs\$Mode-$(Get-Date -Format 'yyyy-MM-dd_HHmm').log") | Out-Null } catch { }
}# $PSScriptRoot is empty inside param() defaults on PowerShell 5.1, so resolve it here
if (-not $Path) { $Path = Join-Path $ScriptDir 'WinSettingsBackup' }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$CV = 'HKCU\Software\Microsoft\Windows\CurrentVersion'

# ---------------- What gets checked ----------------

# User settings, key + subkeys. Every value is compared with the Default user profile; only differences are saved.
$Trees = [ordered]@{
    # Appearance
    'Desktop'          = 'HKCU\Control Panel\Desktop'                  # wallpaper fit, animations, screen saver, snap, per-monitor scaling
    'Colors'           = 'HKCU\Control Panel\Colors'
    'Cursors'          = 'HKCU\Control Panel\Cursors'
    'Themes'           = "$CV\Themes"                                  # dark mode, transparency
    'DWM'              = 'HKCU\Software\Microsoft\Windows\DWM'         # accent color
    'Accent'           = "$CV\Explorer\Accent"
    'Wallpapers'       = "$CV\Explorer\Wallpapers"                     # picture/slideshow/spotlight
    'LockScreen'       = "$CV\Lock Screen"
    'NightLight'       = "$CV\CloudStore\Store\DefaultAccount\Current\default`$windows.data.bluelightreduction.settings"
    'VisualEffects'    = "$CV\Explorer\VisualEffects"                  # Performance Options > Visual Effects
    # Taskbar, Start, File Explorer
    'ExplorerAdvanced' = "$CV\Explorer\Advanced"                       # taskbar buttons/alignment, file extensions, hidden files, Start options
    'TaskbarAutoHide'  = "$CV\Explorer\StuckRects3"
    'TaskbarPins'      = "$CV\Explorer\Taskband"
    'TrayIcons'        = 'HKCU\Control Panel\NotifyIconSettings'
    'Search'           = "$CV\Search"
    'SearchSettings'   = "$CV\SearchSettings"
    'CabinetState'     = "$CV\Explorer\CabinetState"
    'DesktopIcons'     = "$CV\Explorer\HideDesktopIcons"
    'AutoPlay'         = "$CV\Explorer\AutoplayHandlers"               # what happens when you plug in a drive, card, or phone
    'ClassicMenu'      = 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    'FolderViews'      = 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
    'FolderViewsMRU'   = 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU'
    'FolderDefaults'   = "$CV\Explorer\Streams\Defaults"
    # Input
    'Mouse'            = 'HKCU\Control Panel\Mouse'
    'Keyboard'         = 'HKCU\Control Panel\Keyboard'
    'Accessibility'    = 'HKCU\Control Panel\Accessibility'            # sticky/filter/toggle/mouse keys, scrollbars
    'InputHotkeys'     = 'HKCU\Keyboard Layout\Toggle'
    'Touchpad'         = "$CV\PrecisionTouchPad"
    'TouchKeyboard'    = 'HKCU\Software\Microsoft\TabletTip'
    'Typing'           = 'HKCU\Software\Microsoft\Input'               # text suggestions, autocorrect
    # Region
    'International'    = 'HKCU\Control Panel\International'            # formats, home location
    # System
    'Notifications'    = "$CV\Notifications\Settings"
    'SetupSuggestions' = "$CV\UserProfileEngagement"
    'Clipboard'        = 'HKCU\Software\Microsoft\Clipboard'
    'StorageSense'     = "$CV\StorageSense"
    'NearbySharing'    = "$CV\CDP"
    'Graphics'         = 'HKCU\Software\Microsoft\DirectX'             # per-app GPU preference, windowed game optimizations
    'SystemSounds'     = 'HKCU\AppEvents\Schemes'
    'Audio'            = 'HKCU\Software\Microsoft\Multimedia\Audio'    # mono audio, communications ducking
    # Accessibility apps
    'AccessibilityApp' = 'HKCU\Software\Microsoft\Accessibility'       # text size
    'Magnifier'        = 'HKCU\Software\Microsoft\ScreenMagnifier'
    'Narrator'         = 'HKCU\Software\Microsoft\Narrator'
    'ColorFilters'     = 'HKCU\Software\Microsoft\ColorFiltering'
    'Captions'         = "$CV\ClosedCaptioning"
    # Gaming
    'GameBar'          = 'HKCU\Software\Microsoft\GameBar'
    'GameConfig'       = 'HKCU\System\GameConfigStore'
    'GameDVR'          = "$CV\GameDVR"
    # Privacy
    'AdvertisingId'    = "$CV\AdvertisingInfo"
    'Privacy'          = "$CV\Privacy"
    'InkingTyping'     = 'HKCU\Software\Microsoft\InputPersonalization'
    'InkingConsent'    = 'HKCU\Software\Microsoft\Personalization\Settings'
    'OnlineSpeech'     = 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'
    'AppPermissions'   = "$CV\CapabilityAccessManager\ConsentStore"
    'Feedback'         = 'HKCU\Software\Microsoft\Siuf'
    # User policies (Office's are skipped below)
    'UserPolicies'     = 'HKCU\Software\Policies'
    'UserPolicies2'    = "$CV\Policies"
}

# Keys where only the values (not subkeys) are checked, because the subkeys are caches.
$ValueKeys = [ordered]@{
    'ExplorerRoot'    = @{ Key = "$CV\Explorer"; Names = @('ShowCloudFilesInQuickAccess', 'ShowFrequent', 'ShowRecent', 'ShowRecommendations', 'ShellState') }
    'ContentDelivery' = @{ Key = "$CV\ContentDeliveryManager"; Names = $null }   # tips, suggestions, ads, Spotlight
    'Start'           = @{ Key = "$CV\Start"; Names = $null }                    # Start options (subkeys are a tile cache)
    'PushNotify'      = @{ Key = "$CV\PushNotifications"; Names = $null }        # notifications on/off (subkeys are channel caches)
    'Environment'     = @{ Key = 'HKCU\Environment'; Names = $null }             # user environment variables (Path is merged on import)
    'ShellFolders'    = @{ Key = "$CV\Explorer\User Shell Folders"; Names = $null }  # Documents/Downloads/etc. locations
}

# Never captured: app-managed data (Office account and tenant info) and launch timestamps
$SkipKeys = '(?i)\\Cloud\\Office|_ADAL\\|\\JumplistData(\\|$)'
# Never captured: caches, timestamps, and things the import sets itself (wallpaper path, theme file)
$SkipValues = '^(LastUsedTimeStart|LastUsedTimeStop|LastUpdated|TranscodedImageCount|TranscodedImageCache|BingFlightAssignments|SnrBundleVersion|WebView2Version|WebView2RuntimeVersionType|WebViewBundleType|WebViewNavigationInProgress|InstalledPackagedAppsRevision|InstalledWin32AppsRevision|UsingFallbackBundle|WebControlStatus|WebControlSecondaryStatus|IrisClientRefresh|SearchboxTaskbarModeCache|InitialTooltip|WallPaper|CurrentTheme|ThemeMRU|LastHighContrastTheme|BackgroundHistoryPath\d+)$'
# How each area decides what counts as your change. Values the Default profile has and you changed always count.
# Values the Default profile doesn't have are usually Windows' first-sign-in bookkeeping or app data, so:
#   - areas in $KeepAllAreas: any value means you set something, so keep it
#   - areas in $AreaRules: keep only values matching the rule (also applied to the first case)
#   - every other area: drop it, unless a named setting reads it and you changed that setting
$KeepAllAreas = @('ClassicMenu', 'DesktopIcons', 'NightLight', 'Touchpad',
                  'InkingConsent', 'OnlineSpeech', 'Magnifier',
                  'Narrator', 'ColorFilters', 'InputHotkeys', 'Feedback', 'SetupSuggestions', 'FolderDefaults', 'Audio')
$AreaRules = @{
    'AutoPlay'       = { $_.Key -match '\\(UserChosenExecuteHandlers|EventHandlersDefaultSelection)$' -or $_.Name -eq 'DisableAutoplay' }   # not app registrations or known devices
    'Notifications'  = { $_.Name -match '^(Enabled|ShowInActionCenter|ShowBanner|Rank|SoundFile|AllowUrgentNotifications|NOC_GLOBAL_SETTING_.+)$' }
    'AppPermissions' = { $_.Name -eq 'Value' -and $_.Data -eq 'Deny' }    # apps you blocked
    'TrayIcons'      = { $_.Name -eq 'IsPromoted' }                     # which icons you chose to show on the taskbar
    'Graphics'       = { $_.Key -like '*\UserGpuPreferences' }
    'GameDVR'        = { $false }   # what Game Bar writes on first run, plus an error log; Game Mode and the controller button are named settings
    'GameConfig'     = { $false }   # detected games and Game Bar's stock values
    'Captions'       = { $_.Template -ne $null }   # opening the caption page makes an unedited "Default (copy)" theme
    'TaskbarPins'    = { $_.Key -like '*\Taskband' -and $_.Name -in 'Favorites', 'FavoritesResolve', 'FavoritesVersion' }   # the pin list, not change counters or auto-pin flags
    # "Apply to all folders" view templates, not every folder you've opened, and not saved window positions
    'FolderViews'    = { $_.Key -like '*\Bags\AllFolders\Shell\*' -and $_.Name -match '^(Mode|LogicalViewMode|IconSize|Sort|ColInfo|GroupView|GroupByKey:.+|GroupByDirection|FFlags|Vid)$' }
    # Template values you changed, plus your animation choices. Not DPI/monitor bookkeeping or metrics scaled to this screen.
    'Desktop'        = { ($null -ne $_.Template -and $_.Key -notmatch '\\(WindowMetrics|PerMonitorSettings|MuiCached)') -or $_.Name -eq 'UserPreferencesMask' }
    'Cursors'        = { "$($_.Data)" -notmatch '(?i)\\cursors\\aero_' }                     # the stock cursor files
    'StorageSense'   = { $_.Key -like '*\StoragePolicy' -and $_.Name -match '^\d+$' }          # the policy numbers, not caches, suggestions, consent flags, or per-account entries
    'ShellFolders'   = { "$($_.Data)" -notmatch '(?i)\\OneDrive' }                           # OneDrive sets its own folder backup locations
    'Environment'    = { $_.Name -notmatch '^(OneDrive.*|ChocolateyLastPathUpdate)$' }
    'NearbySharing'  = { $_.Name -match 'AuthzPolicy|RemoteLaunch' }                         # not build stamps
    'UserPolicies2'  = { "$($_.Data)" -ne '0' }                                              # 0 means "not restricted"
    'UserPolicies'   = { "$($_.Data)" -ne '0' }
    'InkingTyping'   = { $_.Name -match '^Restrict' }                                        # inking and typing personalization
    'TouchKeyboard'  = { $_.Key -like '*\TabletTip\1.7' -and $_.Name -match '^(Enable|Is|Use|Show)' -and $_.Name -notmatch 'Docked' }
    'Clipboard'      = { $_.Name -match '^Enable' }
    'FolderViewsMRU' = { $false }
    'Typing'         = { $_.Key -like '*\Input\Settings*' }
    'VisualEffects'  = { $_.Key -like '*\VisualEffects' }
    'SearchSettings' = { $_.Key -like '*\SearchSettings' -and $_.Name -match '^(Is|Safe)' }
    'LockScreen'     = { $false }
    'Search'         = { $false }
}
# Values Windows writes holding its own default. Never a change, wherever they turn up.
$KnownDefaults = @{
    'NearbySharing|NearShareChannelUserAuthzPolicy' = '0'; 'NearbySharing|RomeSdkChannelUserAuthzPolicy' = '1'; 'NearbySharing|EnableRemoteLaunchToast' = '1'
    'Audio|ShowDisconnectedDevices' = '1'; 'Audio|VolumeUnits' = '0'
    'Colors|Hilight' = '0 120 212'; 'Colors|MenuHilight' = '0 120 212'
    'Cursors|' = 'Windows Default'
}
# Left out of Diff because they change every time you browse
$NoisyAreas = @('FolderViews', 'FolderViewsMRU')

# Machine-wide values with known defaults. Saved only when changed; applied when Import runs as admin.
# Default '*' = no fixed default, so it's always saved.
function Get-MachineList {
    $m = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion'
    $wu = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $list = @(
        @{ Key = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Default = 1 }
        @{ Key = "$m\Policies\Explorer"; Name = 'NoDriveTypeAutoRun'; Default = 145 }
        @{ Key = "$m\Policies\DataCollection"; Name = 'AllowTelemetry'; Default = 3 }
        @{ Key = "$m\Policies\System"; Name = 'EnableLUA'; Default = 1 }
        @{ Key = "$m\Policies\System"; Name = 'ConsentPromptBehaviorAdmin'; Default = 5 }
        @{ Key = "$m\Policies\System"; Name = 'PromptOnSecureDesktop'; Default = 1 }
        @{ Key = 'HKLM\SYSTEM\CurrentControlSet\Services\tzautoupdate'; Name = 'Start'; Default = '*' }
        @{ Key = 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'; Name = 'Type'; Default = 'NTP' }
        @{ Key = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'; Name = 'fDenyTSConnections'; Default = 1 }
        @{ Key = 'HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance'; Name = 'fAllowToGetHelp'; Default = 1 }
        @{ Key = "$m\AppModelUnlock"; Name = 'AllowDevelopmentWithoutDevLicense'; Default = 0 }
        @{ Key = "$m\Sudo"; Name = 'Enabled'; Default = 0 }
        @{ Key = "$m\Authentication\LogonUI\BootAnimation"; Name = 'DisableStartupSound'; Default = 0 }
        @{ Key = $wu; Name = 'IsContinuousInnovationOptedIn'; Default = 0 }
        @{ Key = $wu; Name = 'SmartActiveHoursState'; Default = 1; Missing = 0 }
        # Start/end only matter when active hours are manual. A missing SmartActiveHoursState means manual.
        @{ Key = $wu; Name = 'ActiveHoursStart'; Default = 8; OnlyIf = { (Or (Get-Reg $wu SmartActiveHoursState) 0) -eq 0 }.GetNewClosure() }
        @{ Key = $wu; Name = 'ActiveHoursEnd'; Default = 17; OnlyIf = { (Or (Get-Reg $wu SmartActiveHoursState) 0) -eq 0 }.GetNewClosure() }
        @{ Key = $wu; Name = 'RestartNotificationsAllowed2'; Default = 0 }
        @{ Key = $wu; Name = 'AllowMUUpdateService'; Default = 0 }
    )
    # Device-level privacy switches (location services, camera access, etc.). Presence sensing defaults to Allow
    # or Deny depending on the hardware, so it's always saved.
    $cs = "$m\CapabilityAccessManager\ConsentStore"
    foreach ($c in @(Get-ChildItem -LiteralPath "Registry::$cs" -EA SilentlyContinue)) {
        if ($null -ne $c.GetValue('Value')) { $list += @{ Key = "$cs\$($c.PSChildName)"; Name = 'Value'; Default = $(if ($c.PSChildName -eq 'humanPresence') { '*' } else { 'Allow' }) } }
    }
    $list
}

# What each machine-wide number means, so reports say "1 (required diagnostic data only)" instead of just "1"
$MachineLabels = @{
    'HiberbootEnabled'                  = @{ '0' = 'fast startup off'; '1' = 'fast startup on' }
    'NoDriveTypeAutoRun'                = {
        param($v)
        $bits = [ordered]@{ 0x01 = 'unknown'; 0x04 = 'removable'; 0x08 = 'fixed/USB hard'; 0x10 = 'network'; 0x20 = 'CD/DVD'; 0x40 = 'RAM disk'; 0x80 = 'unknown type' }
        $off = @(foreach ($p in $bits.GetEnumerator()) { if ([int]$v -band $p.Key) { $p.Value } })
        if ($off) { "AutoPlay blocked on: $($off -join ', ')" } else { 'AutoPlay allowed on all drives' }
    }
    'AllowTelemetry'                    = @{ '0' = 'diagnostic data off, Enterprise only'; '1' = 'required diagnostic data only'; '2' = 'enhanced, legacy'; '3' = 'send optional diagnostic data' }
    'EnableLUA'                         = @{ '0' = 'UAC off'; '1' = 'UAC on' }
    'ConsentPromptBehaviorAdmin'        = @{ '0' = 'elevate without prompting'; '1' = 'ask for password, dimmed desktop'; '2' = 'always notify'; '3' = 'ask for password'; '4' = 'ask for consent'; '5' = 'notify only when apps make changes' }
    'PromptOnSecureDesktop'             = @{ '0' = 'don''t dim the desktop for UAC prompts'; '1' = 'dim the desktop for UAC prompts' }
    'Start'                             = @{ '2' = 'set time zone automatically: on'; '3' = 'set time zone automatically: on'; '4' = 'set time zone automatically: off' }
    'Type'                              = @{ 'NTP' = 'set time automatically: on'; 'NoSync' = 'set time automatically: off'; 'NT5DS' = 'sync with the domain'; 'AllSync' = 'sync with any source' }
    'fDenyTSConnections'                = @{ '0' = 'Remote Desktop on'; '1' = 'Remote Desktop off' }
    'fAllowToGetHelp'                   = @{ '0' = 'Remote Assistance off'; '1' = 'Remote Assistance on' }
    'AllowDevelopmentWithoutDevLicense' = @{ '0' = 'Developer Mode off'; '1' = 'Developer Mode on' }
    'Enabled'                           = @{ '0' = 'sudo off'; '1' = 'sudo: in a new window'; '2' = 'sudo: input disabled'; '3' = 'sudo: inline' }
    'DisableStartupSound'               = @{ '0' = 'startup sound on'; '1' = 'startup sound off' }
    'IsContinuousInnovationOptedIn'     = @{ '0' = 'get latest updates early: off'; '1' = 'get latest updates early: on' }
    'SmartActiveHoursState'             = @{ '0' = 'active hours: manual'; '1' = 'active hours: automatic' }
    'ActiveHoursStart'                  = { param($v) "active hours start at $([datetime]::Today.AddHours([int]$v).ToString('h tt'))" }
    'ActiveHoursEnd'                    = { param($v) "active hours end at $([datetime]::Today.AddHours([int]$v).ToString('h tt'))" }
    'RestartNotificationsAllowed2'      = @{ '0' = 'restart notifications off'; '1' = 'notify me when a restart is needed' }
    'AllowMUUpdateService'              = @{ '0' = 'updates for other Microsoft products: off'; '1' = 'updates for other Microsoft products: on' }
}
function Format-MachineValue($name, $value) {
    if ($null -eq $value -or "$value" -eq '*') { return 'no fixed default' }
    $l = $MachineLabels[$name]
    $text = if ($l -is [scriptblock]) { & $l $value } elseif ($l) { $l["$value"] }
    if ($text) { "$value ($text)" } else { "$value" }
}

$StartPinsDir   ="$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"
$QuickAccess    = "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms"
$PinnedDir      = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned"   # TaskBar\ plus ImplicitAppShortcuts\ (Steam and others)
$TaskbarPinsDir = "$PinnedDir\TaskBar"
$HostsFile      = "$env:SystemRoot\System32\drivers\etc\hosts"
$DefaultHive    = 'WinSettingsDefault'

# ---------------- Helpers ----------------

function Test-RegKey($key) { Test-Path -LiteralPath "Registry::$key" }
$script:ReadLog = $null   # while Get-SettingRows runs, every Get-Reg call is noted so each named setting knows its registry values
function Get-Reg($key, $name) {
    if ($null -ne $script:ReadLog) { $script:ReadLog.Add("$key|$name") }
    (Get-ItemProperty -LiteralPath "Registry::$key" -Name $name -EA SilentlyContinue).$name
}
function OnOff($b) { if ($b) { 'On' } else { 'Off' } }
function Or($v, $d) { if ($null -eq $v -or "$v" -eq '') { $d } else { $v } }
function Mins($s) { if ($s -eq 0) { 'Never' } elseif ($s % 60) { "$s sec" } else { "$($s / 60) min" } }
# Comparable text for a registry value, whether it came from the registry or from JSON
# Same value, allowing for %SystemRoot% vs C:\Windows and letter case in text values
function Test-SameValue($a, $b) { $x = Norm $a; $y = Norm $b; if ($x -eq $y) { return $true }; if ($a -is [string] -and $b -is [string]) { return [Environment]::ExpandEnvironmentVariables($x) -ieq [Environment]::ExpandEnvironmentVariables($y) }; $false }
function Norm($d) { if ($d -is [byte[]]) { [Convert]::ToBase64String($d) } elseif ($d -is [array]) { $d -join '; ' } else { "$d" } }

function Open-RegKey($key, [bool]$write = $false) {
    $hive = if ($key -like 'HKLM\*') { [Microsoft.Win32.Registry]::LocalMachine } elseif ($key -like 'HKU\*') { [Microsoft.Win32.Registry]::Users } else { [Microsoft.Win32.Registry]::CurrentUser }
    $sub = $key.Substring($key.IndexOf('\') + 1)
    if ($write) { $hive.CreateSubKey($sub) } else { $hive.OpenSubKey($sub) }
}

# Values of one key (no subkeys) as plain objects that survive a JSON round trip
function Read-RegValues($key, $names) {
    $k = Open-RegKey $key
    if (-not $k) { return }
    foreach ($n in $k.GetValueNames()) {
        if ($names -and $names -notcontains $n) { continue }
        $data = $k.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
        if ($data -is [byte[]]) { $data = [Convert]::ToBase64String($data) }
        [pscustomobject]@{ Key = $key; Name = $n; Kind = $k.GetValueKind($n).ToString(); Data = $data }
    }
    $k.Close()
}

# The useful part of an error: .NET calls from PowerShell wrap the real message in "Exception calling ..."
function Get-ErrorText($err) { $e = $err.Exception; if ($e.InnerException) { $e.InnerException.Message } else { $e.Message } }

# Where to change values Windows won't let scripts write, by value name
$ProtectedHints = @{ 'TaskbarDa' = 'Settings > Personalization > Taskbar > Widgets' }
# Saved values a policy on this PC already enforces, so there's nothing to write (or diff): Widgets hidden by policy
function Test-PolicyCovers($v) {
    $v.Name -eq 'TaskbarDa' -and "$($v.Data)" -eq '0' -and (Get-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' AllowNewsAndInterests) -eq 0
}
# Windows' error for a failed registry write, plus what it means when it's access denied. On a user value that
# means Windows' User Choice Protection Driver (recent builds) guards it, and only Settings can change it.
function Get-WriteErrorText($v, $err) {
    $msg = Get-ErrorText $err
    $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }
    if ($e -isnot [UnauthorizedAccessException] -and $e -isnot [Security.SecurityException]) { return $msg }
    if ($v.Key -like 'HKLM\*' -and -not $IsAdmin) { return "$msg This needs admin: re-run Run-Import.bat and click Yes." }
    $where = if ($ProtectedHints.ContainsKey([string]$v.Name)) { $ProtectedHints[[string]$v.Name] } else { 'Settings' }
    "$msg Windows protects this value from scripts, so it can't be copied. Change it by hand in $where."
}

# A failed write, spelled out: which setting, its current and imported values (label and raw), and why.
# The named-setting lookups are built on the first failure only, since reading every setting takes a few seconds.
$script:FailLookup = $null
function Format-WriteFailure($v, $err) {
    if (-not $script:FailLookup) {
        $now = @{}; $src = @{}
        foreach ($r in @(Get-SettingRows)) { $now["$($r.Cat)|$($r.Name)"] = $r.Value; foreach ($s in $r.Sources) { if (-not $src.ContainsKey($s)) { $src[$s] = $r } } }
        $was = @{}; foreach ($b in @(Read-JsonArray "$Path\settings.json") + @(Read-JsonArray "$Path\defaults.json")) { $was["$($b.Cat)|$($b.Name)"] = $b.Value }
        $script:FailLookup = @{ Now = $now; Src = $src; Was = $was }
    }
    $raw = { param($d) $t = Norm $d; if ($t.Length -gt 40) { $t.Substring(0, 37) + '...' } else { $t } }
    $cur = (Read-RegValues $v.Key @([string]$v.Name)).Data
    $curRaw = if ($null -eq $cur) { 'value not set' } else { & $raw $cur }
    $newRaw = if ($v.Missing) { 'value not set' } else { & $raw $v.Data }
    $path = "$($v.Key.Substring(5))\$(if ($v.Name -eq '') { '(default)' } else { $v.Name })"
    $r = $script:FailLookup.Src["$($v.Key)|$(if ($v.Name -eq '') { '(default)' } else { $v.Name })"]
    if ($r) {
        $id = "$($r.Cat)|$($r.Name)"
        $label = "$($r.Cat) > $($r.Name)"
        $values = "Current: $($script:FailLookup.Now[$id]) ($curRaw). Imported: $(Or $script:FailLookup.Was[$id] '?') ($newRaw)."
    } else {
        $label = "$(Or $v.Area 'Saved') value"
        $values = "Current: $curRaw. Imported: $newRaw."
    }
    "$label ($path)`n    $values`n    $(Get-WriteErrorText $v $err)"
}

# Writes through .NET so odd key names (brackets, $, *) and default values ("") work
function Write-RegValue($v) {
    if ($v.Kind -notin 'String', 'ExpandString', 'Binary', 'DWord', 'QWord', 'MultiString') { return }
    # Assign inside the switch: a switch's output is a pipeline, which would unroll byte[] and string[] into loose items
    switch ($v.Kind) {
        'Binary'      { $data = [byte[]][Convert]::FromBase64String($v.Data) }
        'MultiString' { $data = [string[]]@($v.Data) }
        'DWord'       { $data = [int]$v.Data }
        'QWord'       { $data = [long]$v.Data }
        default       { $data = [string]$v.Data }
    }
    $k = Open-RegKey $v.Key $true
    $k.SetValue([string]$v.Name, $data, [Microsoft.Win32.RegistryValueKind]$v.Kind)
    $k.Close()
}

# CloudStore settings (Night Light and similar) carry their own timestamp, and Windows keeps whichever copy is
# newest. A backup's copy is always older than this PC's, so it would be put back. Restamp it to now (base64 in and out).
function Update-CloudStoreStamp($data, [long]$t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
    [byte[]]$b = [Convert]::FromBase64String($data)
    $head = [byte[]](0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06)   # then the Unix time as a varint
    if ($b.Length -lt 16) { return $data }
    for ($i = 0; $i -lt $head.Length; $i++) { if ($b[$i] -ne $head[$i]) { return $data } }
    $j = 10; while ($j -lt $b.Length -and ($b[$j] -band 0x80)) { $j++ }; $j++
    $enc = New-Object System.Collections.Generic.List[byte]
    do { $x = [byte]($t -band 0x7F); $t = $t -shr 7; if ($t) { $x = $x -bor 0x80 }; $enc.Add($x) } while ($t)
    [Convert]::ToBase64String([byte[]]($b[0..9] + $enc.ToArray() + $b[$j..($b.Length - 1)]))
}

# PowerShell 5.1's ConvertFrom-Json emits a JSON array as one object, so unroll it
function Read-JsonArray($file) { if (Test-Path $file) { $x = Get-Content $file -Raw | ConvertFrom-Json; foreach ($i in $x) { $i } } }
function Save-Json($obj, $file) { ConvertTo-Json -InputObject $obj -Depth 6 | Set-Content $file -Encoding UTF8 }

# What's actually pinned to the taskbar, read from its pin list: the shortcut files it points at, plus Store apps.
# Leftover shortcut files the pin list doesn't use aren't pins, so they don't count.
function Get-TaskbarPins {
    $fav = Get-Reg "$CV\Explorer\Taskband" Favorites
    if (-not $fav) { return @() }
    # Names sit at both odd and even byte offsets in the pin list, so decode it both ways
    $text = [Text.Encoding]::Unicode.GetString($fav) + '|' + [Text.Encoding]::Unicode.GetString($fav, 1, $fav.Length - 1)
    $names = @(Get-ChildItem -LiteralPath $PinnedDir -Recurse -Filter *.lnk -EA SilentlyContinue | Where-Object { $text.IndexOf($_.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object BaseName)
    $pkgs = [regex]::Matches($text, 'WindowsApps\\([^_\\]+)_') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    if ($pkgs) {
        $start = @(Get-StartApps)
        foreach ($p in $pkgs) { $names += Or (($start | Where-Object { $_.AppID -like "$p`_*" } | Select-Object -First 1).Name) $p }
    }
    @($names | Sort-Object -Unique)
}

function Get-HibernateAvailable { ((powercfg /a | Out-String) -split 'not available')[0] -match 'Hibernate' }

# Hosts entries you added yourself. App-managed sections (like Tailscale's MagicDNS block) are skipped.
function Get-HostsEntries {
    $inApp = $false
    foreach ($l in @(Get-Content $HostsFile -EA SilentlyContinue)) {
        if ($l -match '^#\s*\w+HostsSectionStart') { $inApp = $true; continue }
        if ($l -match '^#\s*\w+HostsSectionEnd') { $inApp = $false; continue }
        if (-not $inApp -and $l -match '^\s*[^#\s]') { $l.Trim() }
    }
}

# Full active power plan, including hidden settings, with this PC's stock defaults
function Get-PowerSettings {
    $scheme = $null; $schemeName = $null; $sub = $null; $cur = $null; $idx = $null
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($line in (powercfg /qh SCHEME_CURRENT)) {
        if ($line -match 'Power Scheme GUID: ([0-9a-f-]{36})\s+\((.*)\)') { $scheme = $matches[1]; $schemeName = $matches[2] }
        elseif ($line -match 'Subgroup GUID: ([0-9a-f-]{36})') { $sub = $matches[1] }
        elseif ($line -match 'Power Setting GUID: ([0-9a-f-]{36})\s+\((.*)\)') {
            $cur = [pscustomobject]@{ Sub = $sub; Guid = $matches[1]; Name = $matches[2]; Units = $null; Options = @{}; AC = $null; DC = $null }
            $list.Add($cur)
        }
        elseif ($line -match 'Possible Setting Index: (\d+)') { $idx = [int]$matches[1] }
        elseif ($line -match 'Possible Setting Friendly Name: (.*)') { $cur.Options["$idx"] = $matches[1].Trim() }
        elseif ($line -match 'Possible Settings units: (.*)') { $cur.Units = $matches[1].Trim() }
        elseif ($line -match 'Current AC Power Setting Index: (0x[0-9a-f]+)') { $cur.AC = [Convert]::ToInt64($matches[1], 16) }
        elseif ($line -match 'Current DC Power Setting Index: (0x[0-9a-f]+)') { $cur.DC = [Convert]::ToInt64($matches[1], 16) }
    }
    # A user (or powercfg) change leaves an override. Values without one are Windows' own tuning for this hardware.
    $ovBase = "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme"
    $defBase = 'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings'
    foreach ($s in $list) {
        $rel = if ($s.Sub -eq 'fea3413e-7e05-4911-9a71-700331f1c294') { $s.Guid } else { "$($s.Sub)\$($s.Guid)" }
        $s | Add-Member ACUser ($null -ne (Get-Reg "$ovBase\$rel" ACSettingIndex))
        $s | Add-Member DCUser ($null -ne (Get-Reg "$ovBase\$rel" DCSettingIndex))
        $s | Add-Member ACDefault (Get-Reg "$defBase\$rel\DefaultPowerSchemeValues\$scheme" AcSettingIndex)
        $s | Add-Member DCDefault (Get-Reg "$defBase\$rel\DefaultPowerSchemeValues\$scheme" DcSettingIndex)
    }
    [pscustomobject]@{ Scheme = $scheme; SchemeName = $schemeName; Settings = $list }
}

function Format-PowerValue($s, $v) {
    if ($null -eq $v) { return '(none)' }
    if ($s.Options.ContainsKey("$v")) { $s.Options["$v"] } elseif ($s.Units -eq 'Seconds') { Mins $v } elseif ($s.Units) { "$v $($s.Units)" } else { "$v" }
}

# Changed power values only: overridden by you and different from the plan's stock default
function Get-PowerChanges($pw) {
    foreach ($s in $pw.Settings) {
        $ac = if ($s.ACUser -and $s.AC -ne $s.ACDefault) { $s.AC } else { $null }
        $dc = if ($s.DCUser -and $s.DC -ne $s.DCDefault) { $s.DC } else { $null }
        if ($null -ne $ac -or $null -ne $dc) {
            [pscustomobject]@{ Sub = $s.Sub; Guid = $s.Guid; Name = $s.Name; AC = $ac; DC = $dc
                ACText = $(if ($null -ne $ac) { Format-PowerValue $s $ac }); ACDefaultText = $(if ($null -ne $ac) { Format-PowerValue $s $s.ACDefault })
                DCText = $(if ($null -ne $dc) { Format-PowerValue $s $dc }); DCDefaultText = $(if ($null -ne $dc) { Format-PowerValue $s $s.DCDefault }) }
        }
    }
}

# Load a copy of the Default user profile (what every new account starts from) to compare against
# Returns the mounted name, or a string starting with "!" that explains why it couldn't
function Mount-DefaultHive {
    if (-not $IsAdmin) { return '!Not running as admin.' }
    if (Test-Path "Registry::HKEY_USERS\$DefaultHive") { cmd /c "reg unload HKU\$DefaultHive >nul 2>&1" }   # left over from a crashed run
    $src = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').Default) + '\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $src)) { return "!Default profile not found at $src." }
    # Load a copy so the real template is never touched. Bring the journal files along, or Windows may refuse a hive with pending changes.
    $copy = Join-Path $env:TEMP 'winsettings_default.dat'
    $errors = @()
    try {
        Copy-Item -LiteralPath $src $copy -Force
        foreach ($log in 'LOG1', 'LOG2') { if (Test-Path -LiteralPath "$src.$log") { Copy-Item -LiteralPath "$src.$log" "$copy.$log" -Force } }
        $out = cmd /c "reg load HKU\$DefaultHive `"$copy`" 2>&1"
        if ($LASTEXITCODE -eq 0) { return $DefaultHive }
        $errors += "copy: $(($out | Out-String).Trim())"
    } catch { $errors += "copy: $($_.Exception.Message)" }
    # Fall back to the original. It's only read, then unloaded.
    $out = cmd /c "reg load HKU\$DefaultHive `"$src`" 2>&1"
    if ($LASTEXITCODE -eq 0) { return $DefaultHive }
    $errors += "original: $(($out | Out-String).Trim())"
    "!Couldn't load the Default user profile ($($errors -join '; '))."
}
function Dismount-DefaultHive {
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    cmd /c "reg unload HKU\$DefaultHive >nul 2>&1"
    Remove-Item "$env:TEMP\winsettings_default.dat*" -Force -EA SilentlyContinue
}

# Every user value that differs from the Default user profile (or every value, if there's no profile to compare with)
function Get-UserChanges($hive) {
    $sources = @()
    foreach ($n in $Trees.Keys) { $sources += , @($n, $Trees[$n], $true, $null) }
    foreach ($n in $ValueKeys.Keys) { $sources += , @($n, $ValueKeys[$n].Key, $false, $ValueKeys[$n].Names) }
    foreach ($src in $sources) {
        $top = Get-Item -LiteralPath "Registry::$($src[1])" -EA SilentlyContinue
        if (-not $top) { continue }
        $keys = @($top)
        if ($src[2]) { $keys += @(Get-ChildItem -LiteralPath "Registry::$($src[1])" -Recurse -EA SilentlyContinue) }
        foreach ($k in $keys) {
            $kp = $k.Name -replace '^HKEY_CURRENT_USER', 'HKCU'
            if ($kp -match $SkipKeys) { continue }
            $bk = if ($hive) { [Microsoft.Win32.Registry]::Users.OpenSubKey("$hive\" + $kp.Substring(5)) } else { $null }
            foreach ($name in $k.GetValueNames()) {
                if ($name -match $SkipValues) { continue }
                if ($src[3] -and $src[3] -notcontains $name) { continue }
                $data = $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
                $inDefault = $false
                if ($bk) {
                    $bd = $bk.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
                    if ($null -ne $bd) { if (Test-SameValue $bd $data) { continue }; $inDefault = $true }
                }
                if ($data -is [byte[]]) { $data = [Convert]::ToBase64String($data) }
                $tmpl = if ($inDefault) { Norm $bd } else { $null }
                $v = [pscustomobject]@{ Area = $src[0]; Key = $kp; Name = $name; Kind = $k.GetValueKind($name).ToString(); Data = $data; Template = $tmpl; Reason = $null }
                if ($hive) {
                    $kd = "$($src[0])|$name"
                    if ($KnownDefaults.ContainsKey($kd) -and "$data" -eq $KnownDefaults[$kd]) { continue }
                    $rule = $AreaRules[$src[0]]
                    if ($rule) { if (-not (@($v) | Where-Object $rule)) { continue } }
                    elseif (-not $inDefault -and $KeepAllAreas -notcontains $src[0]) { continue }
                    $v.Reason = if ($inDefault) { 'Changed from the template' } elseif ($rule) { 'Not in the template; matches this area''s setting filter' } else { 'Not in the template; any value here is a choice you made' }
                } else { $v.Reason = 'No template to compare (export ran without admin)' }
                $v
            }
            if ($bk) { $bk.Close() }
        }
    }
}

# Machine values from Get-MachineList that differ from their default
function Get-MachineChanges {
    foreach ($m in Get-MachineList) {
        if ($m.OnlyIf -and -not (& $m.OnlyIf)) { continue }
        $v = Read-RegValues $m.Key @($m.Name)
        if (-not $v -and $null -ne $m.Missing) { $v = [pscustomobject]@{ Key = $m.Key; Name = $m.Name; Kind = 'DWord'; Data = $m.Missing } }
        if ($v -and ($m.Default -eq '*' -or "$($v.Data)" -ne "$($m.Default)")) { $v | Add-Member Default $m.Default -PassThru }
    }
}

# Machine-level items Windows keeps no defaults for. Recorded for Diff; applied only with -IncludeRecorded.
function Get-Recorded {
    $services = foreach ($k in @(Get-ChildItem -LiteralPath 'Registry::HKLM\SYSTEM\CurrentControlSet\Services' -EA SilentlyContinue)) {
        $type = [int](Or $k.GetValue('Type') 0); $start = $k.GetValue('Start')
        $img = [string]$k.GetValue('ImagePath', $null, 'DoNotExpandEnvironmentNames')
        # Windows' own services only: Win32 service types, not per-user templates/instances, image under the Windows folder
        if ($null -eq $start -or -not ($type -band 0x30) -or ($type -band 0xC0)) { continue }
        if ($k.PSChildName -match '_[0-9a-f]{4,}$') { continue }
        if ($img -notmatch '(?i)^"?(%SystemRoot%|%windir%|C:\\Windows)\\') { continue }
        [pscustomobject]@{ Name = $k.PSChildName; Start = [int]$start; Delayed = [int](Or $k.GetValue('DelayedAutostart') 0) }
    }
    $tasks = @(Get-ScheduledTask -TaskPath '\Microsoft\*' -EA SilentlyContinue | Where-Object State -eq 'Disabled' | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" } | Sort-Object)
    $features = @(Get-CimInstance Win32_OptionalFeature -EA SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Enabled = ($_.InstallState -eq 1) } })
    $named = @(Get-MachineList | ForEach-Object { "$($_.Key)\$($_.Name)" })
    $policies = foreach ($root in 'HKLM\SOFTWARE\Policies', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies') {
        foreach ($k in @(Get-Item -LiteralPath "Registry::$root" -EA SilentlyContinue) + @(Get-ChildItem -LiteralPath "Registry::$root" -Recurse -EA SilentlyContinue)) {
            $kp = $k.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
            if ($kp -match $SkipKeys) { continue }
            foreach ($v in @(Read-RegValues $kp $null)) { if ($v.Name -ne '' -and $named -notcontains "$($v.Key)\$($v.Name)") { $v } }
        }
    }
    [pscustomobject]@{ Services = @($services); DisabledTasks = $tasks; Features = $features; Policies = @($policies) }
}

function Format-Start($s) {
    $l = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }[[int]$s.Start]
    if ($s.Start -eq 2 -and $s.Delayed -eq 1) { 'Automatic (delayed)' } else { $l }
}


# ---------------- Named settings with Windows defaults (feeds CHANGES.md and Diff) ----------------
# Default = $null means there's no fixed Windows default (time zone, languages, etc.).
# -Device means the default varies by PC: Windows picks it from the hardware, manufacturer, or region, or asks
# during setup. Default is then the usual value on a clean retail install, and defaults.json always records it.

# Named settings Import never resets by writing their registry values: power goes through powercfg, time and
# region formats follow the locale, and wallpaper and folder locations point at files on the old PC.
$NoReset = @('Power|*', 'Time and region|*', 'Appearance|Wallpaper', '*|* folder location')
function Test-NoReset($r) { foreach ($p in $NoReset) { if ("$($r.Cat)|$($r.Name)" -like $p) { return $true } }; $false }

function Get-SettingRows {
    $desk = 'HKCU\Control Panel\Desktop'
    $adv  = "$CV\Explorer\Advanced"
    $pers = "$CV\Themes\Personalize"
    $dwm  = 'HKCU\Software\Microsoft\Windows\DWM'
    $cdm  = "$CV\ContentDeliveryManager"
    $hdi  = "$CV\Explorer\HideDesktopIcons\NewStartPanel"
    $mouse = 'HKCU\Control Panel\Mouse'
    $kb   = 'HKCU\Control Panel\Keyboard'
    $intl = 'HKCU\Control Panel\International'
    $ss   = "$CV\SearchSettings"
    $rows = New-Object System.Collections.Generic.List[object]
    $script:ReadLog = New-Object System.Collections.Generic.List[string]
    function Add($cat, $name, $value, $default, [switch]$Device) {
        $rows.Add([pscustomobject]@{ Cat = $cat; Name = $name; Value = "$value"; Default = $(if ($null -eq $default) { $null } else { "$default" }); Device = [bool]$Device; Sources = @($script:ReadLog | Select-Object -Unique) })
        $script:ReadLog.Clear()
    }
    function Shown($v) { if ($v) { 'Shown' } else { 'Hidden' } }

    # Appearance
    $wp = Get-Reg $desk WallPaper
    $wpLabel = 'Windows default'
    if ($wp -and $wp -notlike '*\Windows\Web\Wallpaper\*') {
        $wpLabel = if (Test-Path -LiteralPath $wp) { "Custom image #$((Get-FileHash -LiteralPath $wp -Algorithm MD5).Hash.Substring(0, 8))" } else { 'Custom image (file missing)' }
    }
    Add 'Appearance' 'Wallpaper' $wpLabel 'Windows default'
    $fit = @{ '0' = 'Center'; '2' = 'Stretch'; '6' = 'Fit'; '10' = 'Fill'; '22' = 'Span' }[[string](Or (Get-Reg $desk WallpaperStyle) '10')]
    if ((Get-Reg $desk TileWallpaper) -eq '1') { $fit = 'Tile' }
    Add 'Appearance' 'Wallpaper fit' $fit 'Fill'
    Add 'Appearance' 'Windows mode' $(if ((Or (Get-Reg $pers SystemUsesLightTheme) 1) -eq 1) { 'Light' } else { 'Dark' }) 'Light'
    Add 'Appearance' 'App mode' $(if ((Or (Get-Reg $pers AppsUseLightTheme) 1) -eq 1) { 'Light' } else { 'Dark' }) 'Light'
    Add 'Appearance' 'Transparency effects' (OnOff ((Or (Get-Reg $pers EnableTransparency) 1) -eq 1)) 'On'
    Add 'Appearance' 'Animation effects' (OnOff ((Or (Get-Reg "$desk\WindowMetrics" MinAnimate) '1') -eq '1')) 'On'
    $accent = Get-Reg $dwm AccentColor
    $hex = if ($null -ne $accent) { $h = '{0:X8}' -f $accent; '#' + $h.Substring(6, 2) + $h.Substring(4, 2) + $h.Substring(2, 2) } else { '#0078D4' }
    if ((Get-Reg $desk AutoColorization) -eq 1) { $hex = 'Automatic (from wallpaper)' }
    Add 'Appearance' 'Accent color' $hex '#0078D4'
    Add 'Appearance' 'Accent on Start and taskbar' (OnOff ((Get-Reg $pers ColorPrevalence) -eq 1)) 'Off'
    Add 'Appearance' 'Accent on title bars' (OnOff ((Get-Reg $dwm ColorPrevalence) -eq 1)) 'Off'
    Add 'Appearance' 'Cursor scheme' (Or (Get-Reg 'HKCU\Control Panel\Cursors' '(default)') 'Windows Default') 'Windows Default'
    Add 'Appearance' 'Cursor size' (Or (Get-Reg 'HKCU\Control Panel\Cursors' CursorBaseSize) 32) 32
    Add 'Appearance' 'Lock screen' $(if ((Or (Get-Reg $cdm RotatingLockScreenEnabled) 1) -eq 1) { 'Windows Spotlight' } else { 'Picture or slideshow' }) 'Windows Spotlight'
    Add 'Appearance' 'Lock screen fun facts and tips' (OnOff ((Or (Get-Reg $cdm RotatingLockScreenOverlayEnabled) 1) -eq 1)) 'On'
    $fx = Get-Reg "$CV\Explorer\VisualEffects" VisualFXSetting
    Add 'Appearance' 'Performance visual effects' @{ 0 = 'Let Windows choose'; 1 = 'Best appearance'; 2 = 'Best performance'; 3 = 'Custom' }[[int](Or $fx 0)] 'Let Windows choose'
    Add 'Appearance' 'Screen saver' $(if ((Get-Reg $desk 'SCRNSAVE.EXE')) { Split-Path (Get-Reg $desk 'SCRNSAVE.EXE') -Leaf } else { 'None' }) 'None'

    # Taskbar
    Add 'Taskbar' 'Alignment' $(if ((Or (Get-Reg $adv TaskbarAl) 1) -eq 0) { 'Left' } else { 'Center' }) 'Center'
    # Search box vs icon depends on screen size and build; Widgets and Copilot on region, edition, and manufacturer
    Add 'Taskbar' 'Search' @{ 0 = 'Hidden'; 1 = 'Icon only'; 2 = 'Search box'; 3 = 'Icon and label' }[[int](Or (Get-Reg "$CV\Search" SearchboxTaskbarMode) 2)] 'Search box' -Device
    # A policy that turns Widgets off hides the button whatever TaskbarDa says
    $widgetsOff = (Get-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' AllowNewsAndInterests) -eq 0
    Add 'Taskbar' 'Widgets' (Shown ((-not $widgetsOff) -and (Or (Get-Reg $adv TaskbarDa) 1) -eq 1)) 'Shown' -Device
    Add 'Taskbar' 'Task View button' (Shown ((Or (Get-Reg $adv ShowTaskViewButton) 1) -eq 1)) 'Shown'
    Add 'Taskbar' 'Copilot button' (Shown ((Or (Get-Reg $adv ShowCopilotButton) 1) -eq 1)) 'Shown' -Device
    $sr = Get-Reg "$CV\Explorer\StuckRects3" Settings
    Add 'Taskbar' 'Auto-hide' (OnOff ($sr -and ($sr[8] -band 1))) 'Off'
    Add 'Taskbar' 'Combine buttons' @{ 0 = 'Always'; 1 = 'When full'; 2 = 'Never' }[[int](Or (Get-Reg $adv TaskbarGlomLevel) 0)] 'Always'
    Add 'Taskbar' 'Badges on apps' (OnOff ((Or (Get-Reg $adv TaskbarBadges) 1) -eq 1)) 'On'
    Add 'Taskbar' 'Flashing apps' (OnOff ((Or (Get-Reg $adv TaskbarFlashing) 1) -eq 1)) 'On'
    Add 'Taskbar' 'Seconds in clock' (OnOff ((Get-Reg $adv ShowSecondsInSystemClock) -eq 1)) 'Off'
    Add 'Taskbar' 'End task on right-click' (OnOff ((Get-Reg "$adv\TaskbarDeveloperSettings" TaskbarEndTask) -eq 1)) 'Off'
    $pins = (Get-TaskbarPins) -join ', '
    Add 'Taskbar' 'Pinned apps' $pins $null

    # Start
    Add 'Start' 'Layout' @{ 0 = 'Default'; 1 = 'More pins'; 2 = 'More recommendations' }[[int](Or (Get-Reg $adv Start_Layout) 0)] 'Default'
    Add 'Start' 'Show recently added apps' (OnOff ((Or (Get-Reg "$CV\Start" ShowRecentList) 1) -eq 1)) 'On'
    Add 'Start' 'Show most used apps' (OnOff ((Or (Get-Reg "$CV\Start" ShowFrequentList) 1) -eq 1)) 'On'
    Add 'Start' 'Show recommended files' (OnOff ((Or (Get-Reg $adv Start_TrackDocs) 1) -eq 1)) 'On'
    Add 'Start' 'Show tips and app recommendations' (OnOff ((Or (Get-Reg $adv Start_IrisRecommendations) 1) -eq 1)) 'On'
    Add 'Start' 'Show account notifications' (OnOff ((Or (Get-Reg $adv Start_AccountNotifications) 1) -eq 1)) 'On'

    # File Explorer and desktop
    $fe = 'File Explorer and desktop'
    Add $fe 'Hidden files' (Shown ((Or (Get-Reg $adv Hidden) 2) -eq 1)) 'Hidden'
    Add $fe 'File extensions' (Shown ((Or (Get-Reg $adv HideFileExt) 1) -eq 0)) 'Hidden'
    Add $fe 'Protected OS files' (Shown ((Get-Reg $adv ShowSuperHidden) -eq 1)) 'Hidden'
    Add $fe 'Opens to' @{ 1 = 'This PC'; 2 = 'Home'; 3 = 'Downloads'; 4 = 'OneDrive' }[[int](Or (Get-Reg $adv LaunchTo) 2)] 'Home'
    Add $fe 'Full path in title bar' (OnOff ((Get-Reg "$CV\Explorer\CabinetState" FullPath) -eq 1)) 'Off'
    Add $fe 'Right-click menu' $(if (Test-RegKey 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32') { 'Classic (Win10 style)' } else { 'Win11 compact menu' }) 'Win11 compact menu'
    Add $fe 'Show recent files in Home' (OnOff ((Or (Get-Reg "$CV\Explorer" ShowRecent) 1) -eq 1)) 'On'
    Add $fe 'Show frequent folders in Home' (OnOff ((Or (Get-Reg "$CV\Explorer" ShowFrequent) 1) -eq 1)) 'On'
    Add $fe 'Show files from Office.com' (OnOff ((Or (Get-Reg "$CV\Explorer" ShowCloudFilesInQuickAccess) 1) -eq 1)) 'On'
    Add $fe 'Navigation pane: show all folders' (OnOff ((Get-Reg $adv NavPaneShowAllFolders) -eq 1)) 'Off'
    Add $fe 'Navigation pane: expand to open folder' (OnOff ((Get-Reg $adv NavPaneExpandToCurrentFolder) -eq 1)) 'Off'
    Add $fe 'Sync provider notifications' (OnOff ((Or (Get-Reg $adv ShowSyncProviderNotifications) 1) -eq 1)) 'On'
    Add $fe 'Compact view' (OnOff ((Get-Reg $adv UseCompactMode) -eq 1)) 'Off'
    Add $fe 'Item check boxes' (OnOff ((Get-Reg $adv AutoCheckSelect) -eq 1)) 'Off'
    Add $fe 'Desktop icons visible' (Shown ((Get-Reg $adv HideIcons) -ne 1)) 'Shown'
    $icons = [ordered]@{
        'This PC'       = @('{20D04FE0-3AEA-1069-A2D8-08002B30309D}', 1)
        'Recycle Bin'   = @('{645FF040-5081-101B-9F08-00AA002F954E}', 0)
        'User folder'   = @('{59031a47-3f72-44a7-89c5-5595fe6b30ee}', 1)
        'Network'       = @('{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}', 1)
        'Control Panel' = @('{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}', 1)
    }
    foreach ($i in $icons.Keys) {
        Add $fe "$i icon on desktop" (Shown ((Or (Get-Reg $hdi $icons[$i][0]) $icons[$i][1]) -ne 1)) (Shown ($icons[$i][1] -ne 1))
    }
    foreach ($f in 'Personal', '{374DE290-123F-4565-9164-39C4925E467B}', 'My Pictures', 'My Video', 'My Music', 'Desktop') {
        $label = @{ 'Personal' = 'Documents'; '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'; 'My Pictures' = 'Pictures'; 'My Video' = 'Videos'; 'My Music' = 'Music'; 'Desktop' = 'Desktop' }[$f]
        $v = (Read-RegValues "$CV\Explorer\User Shell Folders" @($f)).Data
        $def = "%USERPROFILE%\$label"
        Add $fe "$label folder location" (Or $v $def) $def
    }

    # System
    Add 'System' 'Notifications' (OnOff ((Or (Get-Reg "$CV\PushNotifications" ToastEnabled) 1) -eq 1)) 'On'
    Add 'System' 'Windows welcome experience after updates' (OnOff ((Or (Get-Reg $cdm 'SubscribedContent-310093Enabled') 1) -eq 1)) 'On'
    Add 'System' 'Tips and suggestions' (OnOff ((Or (Get-Reg $cdm 'SubscribedContent-338389Enabled') 1) -eq 1)) 'On'
    Add 'System' 'Suggest ways to finish setting up' (OnOff ((Or (Get-Reg "$CV\UserProfileEngagement" ScoobeSystemSettingEnabled) 1) -eq 1)) 'On'
    Add 'System' 'Clipboard history' (OnOff ((Get-Reg 'HKCU\Software\Microsoft\Clipboard' EnableClipboardHistory) -eq 1)) 'Off'
    Add 'System' 'Storage Sense' (OnOff ((Get-Reg "$CV\StorageSense\Parameters\StoragePolicy" '01') -eq 1)) 'Off'
    Add 'System' 'Snap windows' (OnOff ((Or (Get-Reg $desk WindowArrangementActive) '1') -eq '1')) 'On'
    Add 'System' 'Snap layouts on maximize hover' (OnOff ((Or (Get-Reg $adv EnableSnapAssistFlyout) 1) -eq 1)) 'On'
    Add 'System' 'Title bar shake to minimize' (OnOff ((Or (Get-Reg $adv DisallowShaking) 1) -eq 0)) 'Off'
    $scheme = [string](Or (Get-Reg 'HKCU\AppEvents\Schemes' '(default)') '.Default')
    $sounds = @{ '.Default' = 'Windows Default'; '.None' = 'No Sounds'; '.Modified' = 'Modified (individual sounds changed)' }[$scheme]
    Add 'System' 'System sounds' (Or $sounds $scheme) 'Windows Default'
    Add 'System' 'Communications ducking' @{ 0 = 'Mute other sounds'; 1 = 'Reduce by 80%'; 2 = 'Reduce by 50%'; 3 = 'Do nothing' }[[int](Or (Get-Reg 'HKCU\Software\Microsoft\Multimedia\Audio' UserDuckingPreference) 1)] 'Reduce by 80%'
    $machine = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion'
    # Manufacturers often turn fast startup and the startup sound off
    Add 'System' 'Fast startup' (OnOff ((Or (Get-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled) 1) -eq 1)) 'On' -Device
    Add 'System' 'Hibernate available' (OnOff (Get-HibernateAvailable)) $null
    Add 'System' 'Startup sound' (OnOff ((Get-Reg "$machine\Authentication\LogonUI\BootAnimation" DisableStartupSound) -ne 1)) 'On' -Device
    Add 'System' 'Remote Desktop' (OnOff ((Or (Get-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections) 1) -eq 0)) 'Off'
    Add 'System' 'Developer Mode' (OnOff ((Get-Reg "$machine\AppModelUnlock" AllowDevelopmentWithoutDevLicense) -eq 1)) 'Off'
    Add 'System' 'Sudo' (OnOff ((Get-Reg "$machine\Sudo" Enabled) -ge 1)) 'Off'
    Add 'System' 'Get latest updates as soon as available' (OnOff ((Get-Reg 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' IsContinuousInnovationOptedIn) -eq 1)) 'Off'
    $wu = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $ah = if ((Or (Get-Reg $wu SmartActiveHoursState) 0) -eq 1) { 'Automatic' } else { "Manual $(Get-Reg $wu ActiveHoursStart):00-$(Get-Reg $wu ActiveHoursEnd):00" }
    Add 'System' 'Active hours' $ah 'Automatic'
    Add 'System' 'Remote Assistance' (OnOff ((Or (Get-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance' fAllowToGetHelp) 1) -eq 1)) 'On'
    # Hosts entries you added (app-managed sections like Tailscale's are skipped)
    Add 'System' 'Custom hosts file entries' @(Get-HostsEntries).Count 0

    # Devices: AutoPlay
    $ap = "$CV\Explorer\AutoplayHandlers"
    Add 'Devices' 'Use AutoPlay for all media and devices' (OnOff ((Get-Reg $ap DisableAutoplay) -ne 1)) 'On'
    # Machine policy that blocks AutoPlay per drive type, overriding the choices below. Bit 0x04 = removable drives.
    $block = [int](Or (Or (Get-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' NoDriveTypeAutoRun) (Get-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' NoDriveTypeAutoRun)) 0x91)
    Add 'Devices' 'AutoPlay allowed on removable drives (policy)' (OnOff (-not ($block -band 0x04))) 'On'
    Add 'Devices' 'AutoPlay allowed on internal/USB hard drives (policy)' (OnOff (-not ($block -band 0x08))) 'On'
    $handlers = @{ 'MSOpenFolder' = 'Open folder to view files'; 'MSTakeNoAction' = 'Take no action'; 'MSPromptEachTime' = 'Ask me every time'; 'MSStorageSense' = 'Configure storage settings' }
    foreach ($e in @(@('Removable drive', 'StorageOnArrival'), @('Memory card', 'CameraAlternate\ShowPicturesOnArrival'))) {
        # "Take no action"/"Open folder" land in UserChosenExecuteHandlers; app choices in EventHandlersDefaultSelection
        $h = Or (Get-Reg "$ap\UserChosenExecuteHandlers" $e[1]) (Get-Reg "$ap\EventHandlersDefaultSelection" $e[1])
        Add 'Devices' "AutoPlay: $($e[0])" (Or $handlers[[string]$h] (Or $h 'Ask me every time')) 'Ask me every time'
    }

    # Mouse and keyboard
    $mk = 'Mouse and keyboard'
    Add $mk 'Enhance pointer precision (acceleration)' (OnOff ((Or (Get-Reg $mouse MouseSpeed) '1') -ne '0')) 'On'
    Add $mk 'Pointer speed' "$(Or (Get-Reg $mouse MouseSensitivity) 10) of 20" '10 of 20'
    Add $mk 'Primary button' $(if ((Get-Reg $mouse SwapMouseButtons) -eq '1') { 'Right' } else { 'Left' }) 'Left'
    Add $mk 'Double-click speed' "$(Or (Get-Reg $mouse DoubleClickSpeed) 500) ms" '500 ms'
    Add $mk 'Scroll lines per notch' (Or (Get-Reg $desk WheelScrollLines) 3) 3
    Add $mk 'Scroll inactive windows on hover' (OnOff ((Or (Get-Reg $desk MouseWheelRouting) 2) -eq 2)) 'On'
    Add $mk 'Key repeat delay' (Or (Get-Reg $kb KeyboardDelay) 1) 1
    Add $mk 'Key repeat rate' (Or (Get-Reg $kb KeyboardSpeed) 31) 31
    Add $mk 'Num Lock at sign-in' (OnOff ([int64](Or (Get-Reg $kb InitialKeyboardIndicators) 0) -band 2)) 'Off' -Device   # set by the manufacturer or firmware
    Add $mk 'Print Screen opens Snipping Tool' (OnOff ((Or (Get-Reg $kb PrintScreenKeyForSnippingEnabled) 1) -eq 1)) 'On'
    $hk = @{ '1' = 'Left Alt+Shift'; '2' = 'Ctrl+Shift'; '3' = 'Not assigned'; '4' = 'Grave accent' }
    Add $mk 'Switch input language hotkey' $hk[[string](Or (Get-Reg 'HKCU\Keyboard Layout\Toggle' 'Language Hotkey') '1')] 'Left Alt+Shift'
    Add $mk 'Switch keyboard layout hotkey' $hk[[string](Or (Get-Reg 'HKCU\Keyboard Layout\Toggle' 'Layout Hotkey') '2')] 'Ctrl+Shift'

    # Accessibility
    $acc = [ordered]@{
        'Sticky Keys' = @('StickyKeys', 510, 'press Shift 5 times')
        'Filter Keys' = @('Keyboard Response', 126, 'hold right Shift 8 sec')
        'Toggle Keys' = @('ToggleKeys', 62, 'hold Num Lock 5 sec')
        'Mouse Keys'  = @('MouseKeys', 62, 'left Alt + left Shift + Num Lock')
    }
    foreach ($f in $acc.Keys) {
        # Flags bit 0x1 = feature on, 0x4 = keyboard shortcut enabled
        $flags = [int](Or (Get-Reg "HKCU\Control Panel\Accessibility\$($acc[$f][0])" Flags) $acc[$f][1])
        Add 'Accessibility' $f (OnOff ($flags -band 1)) (OnOff ($acc[$f][1] -band 1))
        Add 'Accessibility' "$f shortcut ($($acc[$f][2]))" (OnOff ($flags -band 4)) (OnOff ($acc[$f][1] -band 4))
    }
    Add 'Accessibility' 'Text size' "$(Or (Get-Reg 'HKCU\Software\Microsoft\Accessibility' TextScaleFactor) 100)%" '100%'
    Add 'Accessibility' 'Always show scrollbars' (OnOff ((Or (Get-Reg 'HKCU\Control Panel\Accessibility' DynamicScrollbars) 1) -eq 0)) 'Off'
    Add 'Accessibility' 'Mono audio' (OnOff ((Get-Reg 'HKCU\Software\Microsoft\Multimedia\Audio' AccessibilityMonoMixState) -eq 1)) 'Off'
    Add 'Accessibility' 'Text cursor thickness' (Or (Get-Reg $desk CaretWidth) 1) 1

    # Gaming
    Add 'Gaming' 'Game Mode' (OnOff ((Or (Get-Reg 'HKCU\Software\Microsoft\GameBar' AutoGameModeEnabled) 1) -eq 1)) 'On'
    Add 'Gaming' 'Controller opens Game Bar' (OnOff ((Or (Get-Reg 'HKCU\Software\Microsoft\GameBar' UseNexusForGameBarEnabled) 1) -eq 1)) 'On'

    # Privacy and search
    $pv = 'Privacy and search'
    # Diagnostic data, advertising ID, tailored experiences, and location are asked during setup, so they vary by PC
    Add $pv 'Send optional diagnostic data' (OnOff ((Or (Get-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' AllowTelemetry) 3) -ge 3)) 'On' -Device
    # UAC slider: EnableLUA 0 = off; ConsentPromptBehaviorAdmin 2 = always notify, 5 = notify on app changes, 0 = never; PromptOnSecureDesktop = dim desktop
    $uacKey = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $cpba = [int](Or (Get-Reg $uacKey ConsentPromptBehaviorAdmin) 5); $posd = [int](Or (Get-Reg $uacKey PromptOnSecureDesktop) 1)
    $uac = if ((Or (Get-Reg $uacKey EnableLUA) 1) -eq 0 -or $cpba -eq 0) { 'Never notify' } elseif ($cpba -eq 2) { 'Always notify' } elseif ($posd -eq 1) { 'Notify on app changes, dim desktop' } else { 'Notify on app changes, no dimming' }
    Add $pv 'User Account Control level' $uac 'Notify on app changes, dim desktop'
    Add $pv 'Advertising ID' (OnOff ((Or (Get-Reg "$CV\AdvertisingInfo" Enabled) 1) -eq 1)) 'On' -Device
    Add $pv 'Tailored experiences' (OnOff ((Or (Get-Reg "$CV\Privacy" TailoredExperiencesWithDiagnosticDataEnabled) 1) -eq 1)) 'On' -Device
    Add $pv 'Websites can use my language list' (OnOff ((Get-Reg "$intl\User Profile" HttpAcceptLanguageOptOut) -ne 1)) 'On'
    Add $pv 'Track app launches' (OnOff ((Or (Get-Reg $adv Start_TrackProgs) 1) -eq 1)) 'On'
    Add $pv 'Suggested content in Settings' (OnOff ((Or (Get-Reg $cdm 'SubscribedContent-338393Enabled') 1) -eq 1)) 'On'
    Add $pv 'SafeSearch' @{ 0 = 'Off'; 1 = 'Moderate'; 2 = 'Strict' }[[int](Or (Get-Reg $ss SafeSearchMode) 1)] 'Moderate'
    Add $pv 'Search history on this device' (OnOff ((Or (Get-Reg $ss IsDeviceSearchHistoryEnabled) 1) -eq 1)) 'On'
    Add $pv 'Search highlights' (OnOff ((Or (Get-Reg $ss IsDynamicSearchBoxEnabled) 1) -eq 1)) 'On'
    Add $pv 'Search Microsoft account content' (OnOff ((Or (Get-Reg $ss IsMSACloudSearchEnabled) 1) -eq 1)) 'On'
    $cs = "$CV\CapabilityAccessManager\ConsentStore"
    Add $pv 'Location services' (Or (Get-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' Value) 'Allow') 'Allow' -Device
    Add $pv 'Apps can use location' (Or (Get-Reg "$cs\location" Value) 'Allow') 'Allow' -Device
    Add $pv 'Apps can use camera' (Or (Get-Reg "$cs\webcam" Value) 'Allow') 'Allow'
    Add $pv 'Apps can use microphone' (Or (Get-Reg "$cs\microphone" Value) 'Allow') 'Allow'

    # Time and region
    $tr = 'Time and region'
    Add $tr 'Time zone' (tzutil /g) $null
    Add $tr 'Set time zone automatically' (OnOff ((Get-Reg 'HKLM\SYSTEM\CurrentControlSet\Services\tzautoupdate' Start) -eq 3)) $null
    Add $tr 'Set time automatically' (OnOff ((Or (Get-Reg 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' Type) 'NTP') -ne 'NoSync')) 'On'
    # The language list doesn't unroll in a pipeline, so use foreach
    Add $tr 'Languages' (@(foreach ($l in (Get-WinUserLanguageList)) { $l.LanguageTag }) -join ', ') $null
    Add $tr 'System locale (non-Unicode programs)' (Get-WinSystemLocale).Name $null
    Add $tr 'Regional format' (Or (Get-Reg $intl LocaleName) 'en-US') $null
    # Format defaults come from the locale itself, ignoring user overrides
    $loc = Or (Get-Reg $intl LocaleName) 'en-US'
    $dtf = ([Globalization.CultureInfo]::GetCultureInfo($loc)).DateTimeFormat
    Add $tr 'Short date' (Or (Get-Reg $intl sShortDate) $dtf.ShortDatePattern) $dtf.ShortDatePattern
    Add $tr 'Long date' (Or (Get-Reg $intl sLongDate) $dtf.LongDatePattern) $dtf.LongDatePattern
    Add $tr 'Short time' (Or (Get-Reg $intl sShortTime) $dtf.ShortTimePattern) $dtf.ShortTimePattern
    Add $tr 'Long time' (Or (Get-Reg $intl sTimeFormat) $dtf.LongTimePattern) $dtf.LongTimePattern
    $days = 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
    $defDay = ([int]$dtf.FirstDayOfWeek + 6) % 7
    Add $tr 'First day of week' $days[[int](Or (Get-Reg $intl iFirstDayOfWeek) $defDay)] $days[$defDay]
    $metric = ([Globalization.RegionInfo]::new($loc)).IsMetric
    Add $tr 'Measurement' $(if ((Or (Get-Reg $intl iMeasure) $(if ($metric) { 0 } else { 1 })) -eq '0') { 'Metric' } else { 'US' }) $(if ($metric) { 'Metric' } else { 'US' })

    # Power: only values you overrode. The rest are Windows' own tuning for this hardware and shift on their own.
    $pw = Get-PowerSettings
    Add 'Power' 'Active power plan' $pw.SchemeName $null
    foreach ($s in $pw.Settings) {
        foreach ($side in @(@('AC', 'plugged in'), @('DC', 'battery'))) {
            if (-not $s.("$($side[0])User")) { continue }
            $def = $s.("$($side[0])Default")
            if ($null -eq $def) { continue }
            $fmt = {
                param($v)
                if ($s.Options.ContainsKey("$v")) { $s.Options["$v"] }
                elseif ($s.Units -eq 'Seconds') { Mins $v }
                elseif ($s.Units) { "$v $($s.Units)" } else { "$v" }
            }
            Add 'Power' "$($s.Name) ($($side[1]))" (& $fmt ($s.($side[0]))) (& $fmt $def)
        }
    }
    $script:ReadLog = $null
    $rows
}


function Write-ChangesReport($rows, $file, $user, $machine, $recorded, [bool]$haveBaseline) {
    $known   = @($rows | Where-Object { $null -ne $_.Default })
    $changed = @($known | Where-Object { $_.Value -ne $_.Default })
    $same    = @($known | Where-Object { $_.Value -eq $_.Default })
    $info    = @($rows | Where-Object { $null -eq $_.Default })
    $md = @('# Windows settings changes', '',
            "Exported from **$env:COMPUTERNAME** on $(Get-Date -Format 'yyyy-MM-dd h:mm tt'). The backup holds only what's listed here as changed, plus the items with no fixed default.", '',
            "$($changed.Count) of $($known.Count) named settings have been changed from the Windows default.", '',
            '## Changed from default', '')
    foreach ($g in ($changed | Group-Object Cat)) {
        $md += "### $($g.Name)", '', '| Setting | Yours | Default |', '|---|---|---|'
        $md += $g.Group | ForEach-Object { "| $($_.Name) | $($_.Value) | $($_.Default) |" }
        $md += ''
    }
    $md += '## No fixed default', '', 'These depend on where you live or what you set up, so they''re always saved.', '', '| Setting | Yours |', '|---|---|'
    $md += $info | ForEach-Object { "| $($_.Name) | $($_.Value) |" }

    $md += '', '## Other saved changes', ''
    if ($haveBaseline) {
        $md += "$(@($user).Count) more values differ from the Default user profile (folder views, per-app notifications, Night light, touchpad, and so on). They're restored on import but don't have simple labels. See `CHANGES_LONG.md` for every one in detail.", '', '| Area | Values |', '|---|---|'
        $md += @($user) | Group-Object Area | Sort-Object Count -Descending | ForEach-Object { "| $($_.Name) | $($_.Count) |" }
    } else {
        $md += "Export didn't run as admin, so there was no Default user profile to compare with. All $(@($user).Count) user values were saved, not just your changes. Run Run-Export.bat and click Yes for a changes-only backup."
    }
    $md += '', '## Machine-wide changes', '', 'Applied when Run-Import.bat runs as admin.', ''
    if (@($machine).Count) {
        $md += '| Value | Yours | Default |', '|---|---|---|'
        $md += @($machine) | ForEach-Object { "| ``$($_.Key)\$($_.Name)`` | $(Format-MachineValue $_.Name $_.Data) | $(Format-MachineValue $_.Name $_.Default) |" }
    } else { $md += 'None.' }

    $disabledSvc = @($recorded.Services | Where-Object Start -eq 4 | ForEach-Object Name | Sort-Object)
    $onFeatures = @($recorded.Features | Where-Object Enabled | ForEach-Object Name | Sort-Object)
    $md += '', '## Recorded, not applied', '',
           'Windows keeps no defaults for these, so the tool can''t tell your changes from stock values. Run-Diff shows differences, and `-IncludeRecorded` on import applies them.', '',
           '<details><summary>Show recorded items</summary>', '',
           "**Disabled Windows services ($($disabledSvc.Count)):** $($disabledSvc -join ', ')", '',
           "**Optional features turned on ($($onFeatures.Count)):** $($onFeatures -join ', ')", '',
           "**Disabled Microsoft scheduled tasks ($(@($recorded.DisabledTasks).Count)):** $(@($recorded.DisabledTasks) -join ', ')", '',
           "**Other machine policies:** $(@($recorded.Policies).Count) values", '', '</details>', ''
    $md += '## Still at default', '', 'Saved in `defaults.json`. Import resets these on the new PC only with `OverwriteChangedSettings`, or `ApplyDeviceDefaults` for the ones marked "varies by PC".', ''
    foreach ($g in ($same | Group-Object Cat)) {
        $md += "**$($g.Name):** " + (($g.Group | ForEach-Object { "$($_.Name) ($($_.Value)$(if ($_.Device) { ', varies by PC' }))" }) -join ', ')
        $md += ''
    }
    $md | Set-Content $file -Encoding UTF8
    $changed.Count
}

# CHANGES_LONG.md: everything the backup holds, in full detail, built from the backup's own files
function Write-LongReport($Path) {
    $esc = { param($s) ("$s" -replace '\|', '\|' -replace "`r?`n", ' ') }
    $fmt = {
        param($kind, $data)
        if ($null -eq $data) { return '' }
        switch ($kind) {
            'DWord'       { '{0} (0x{1:X8})' -f $data, ([int]$data) }
            'Binary'      { $b = [Convert]::FromBase64String("$data"); $hex = ($b | Select-Object -First 24 | ForEach-Object { '{0:X2}' -f $_ }) -join ' '; "binary, $($b.Length) bytes: $hex$(if ($b.Length -gt 24) { ' ...' })" }
            'MultiString' { (@($data) -join ' ; ') }
            default       { if ("$data" -eq '') { '(empty)' } else { "$data" } }
        }
    }
    $meta = Get-Content "$Path\meta.json" -Raw | ConvertFrom-Json
    $rows = @(Read-JsonArray "$Path\settings.json")
    $user = @(Read-JsonArray "$Path\values.json")
    $machine = @(Read-JsonArray "$Path\machine.json")
    $power = Get-Content "$Path\power.json" -Raw | ConvertFrom-Json
    $sys = Get-Content "$Path\system.json" -Raw | ConvertFrom-Json
    $rec = Get-Content "$Path\recorded.json" -Raw | ConvertFrom-Json
    $defaults = @(Read-JsonArray "$Path\defaults.json")
    $changed = @($rows | Where-Object { $null -ne $_.Default })
    $info = @($rows | Where-Object { $null -eq $_.Default })

    $md = @('# Windows settings changes, full detail', '',
            "Backup from **$($meta.Computer)**, exported $($meta.Date)$(if (-not $meta.Baseline) { ' **without admin**, so user values weren''t compared with the Default profile and every value was saved' }).", '',
            'This lists every item the backup holds. `CHANGES.md` is the short version.', '',
            '| Section | Items |', '|---|---|',
            "| 1. Named settings changed from default | $($changed.Count) |",
            "| 2. Named settings with no fixed default | $($info.Count) |",
            "| 3. Saved user registry values | $($user.Count) |",
            "| 4. Machine-wide changes | $($machine.Count) |",
            "| 5. Power plan changes | $(@($power.Settings).Count) |",
            "| 6. Time, language, and system | $(4 + @($sys.HostsEntries).Count) |",
            "| 7. Files | $(@(Get-ChildItem "$Path\files" -Recurse -File -EA SilentlyContinue).Count) |",
            "| 8. Recorded, not applied by default | $(@($rec.Services).Count + @($rec.DisabledTasks).Count + @($rec.Features).Count + @($rec.Policies).Count) |",
            "| 9. Named settings at default | $(@($defaults).Count) |", '')

    $md += '## 1. Named settings changed from default', '', '| Category | Setting | Yours | Default | Registry values it reads |', '|---|---|---|---|---|'
    $md += $changed | ForEach-Object { "| $($_.Cat) | $($_.Name) | $(& $esc $_.Value) | $(& $esc $_.Default) | $((@($_.Sources) | ForEach-Object { '`' + $_.Replace('|', '\') + '`' }) -join '<br>') |" }

    $md += '', '## 2. Named settings with no fixed default', '', '| Category | Setting | Yours |', '|---|---|---|'
    $md += $info | ForEach-Object { "| $($_.Cat) | $($_.Name) | $(& $esc $_.Value) |" }

    $md += '', '## 3. Saved user registry values', '', 'Every value import writes under your user account. **Template** is what the Default user profile (the starting point for new accounts) had; blank means it didn''t have the value at all.', ''
    foreach ($g in ($user | Group-Object Area | Sort-Object Name)) {
        $md += "### $($g.Name) ($($g.Count))", '', '| Key | Value | Type | Yours | Template | Why it''s saved |', '|---|---|---|---|---|---|'
        $md += $g.Group | Sort-Object Key, Name | ForEach-Object {
            $tm = if ($null -ne $_.Template) { & $fmt $_.Kind $(if ($_.Kind -eq 'Binary') { $_.Template } else { $_.Template }) } else { '' }
            "| ``$($_.Key)`` | $(if ($_.Name -eq '') { '(default)' } else { & $esc $_.Name }) | $($_.Kind) | $(& $esc (& $fmt $_.Kind $_.Data)) | $(& $esc $tm) | $(Or $_.Reason '') |"
        }
        $md += ''
    }

    $md += '## 4. Machine-wide changes', '', 'Applied when import runs as admin.', '', '| Key | Value | Type | Yours | Default |', '|---|---|---|---|---|'
    $md += $machine | ForEach-Object { "| ``$($_.Key)`` | $($_.Name) | $($_.Kind) | $(& $esc (Format-MachineValue $_.Name $_.Data)) | $(& $esc (Format-MachineValue $_.Name $_.Default)) |" }

    $md += '', '## 5. Power plan changes', '', "Plan: $($power.SchemeName) (``$($power.Scheme)``). Only values you overrode that differ from the plan's stock default.", '',
           '| Setting | Plugged in: yours | Plugged in: default | Battery: yours | Battery: default | GUIDs |', '|---|---|---|---|---|---|'
    $md += @($power.Settings) | ForEach-Object { "| $($_.Name) | $(Or $_.ACText $(if ($null -ne $_.AC) { $_.AC } else { '-' })) | $(Or $_.ACDefaultText '-') | $(Or $_.DCText $(if ($null -ne $_.DC) { $_.DC } else { '-' })) | $(Or $_.DCDefaultText '-') | ``$($_.Sub)\$($_.Guid)`` |" }

    $md += '', '## 6. Time, language, and system', '', '| Item | Value |', '|---|---|',
           "| Time zone | $($sys.TimeZone) |",
           "| Languages and keyboards | $((@($sys.Languages) | ForEach-Object { "$($_.Tag) ($(@($_.Inputs) -join ', '))" }) -join '; ') |",
           "| System locale | $($sys.SystemLocale) |",
           "| Hibernate available | $($sys.HibernateAvailable) |"
    $md += @($sys.HostsEntries) | ForEach-Object { "| Hosts entry | ``$_`` |" }

    $md += '', '## 7. Files', '', '| File | Size | What it is |', '|---|---|---|'
    $what = { param($n) switch -Wildcard ($n) { 'wallpaper.*' { 'Desktop wallpaper' } 'lockscreen.jpg' { 'Lock screen picture' } 'start*.bin' { 'Start menu pins and layout' } 'quickaccess.bin' { 'Quick access pins' } '*.lnk' { 'Taskbar pin shortcut' } default { '' } } }
    $md += Get-ChildItem "$Path\files" -Recurse -File -EA SilentlyContinue | ForEach-Object { "| ``$($_.FullName.Substring("$Path\files\".Length))`` | $([math]::Round($_.Length / 1KB, 1)) KB | $(& $what $_.Name) |" }

    $md += '', '## 8. Recorded, not applied by default', '', 'Windows keeps no defaults for these, so they''re recorded for Diff and applied only with `-IncludeRecorded`.', ''
    $md += "### Windows services ($(@($rec.Services).Count))", '', '| Service | Startup type |', '|---|---|'
    $md += @($rec.Services) | Sort-Object Name | ForEach-Object { "| $($_.Name) | $(Format-Start $_) |" }
    $md += '', "### Disabled Microsoft scheduled tasks ($(@($rec.DisabledTasks).Count))", ''
    $md += @($rec.DisabledTasks) | ForEach-Object { "- ``$_``" }
    $md += '', "### Optional features ($(@($rec.Features).Count))", '', '| Feature | State |', '|---|---|'
    $md += @($rec.Features) | Sort-Object @{ e = { -not $_.Enabled } }, Name | ForEach-Object { "| $($_.Name) | $(if ($_.Enabled) { 'On' } else { 'Off' }) |" }
    $md += '', "### Machine policies ($(@($rec.Policies).Count))", '', '| Key | Value | Type | Data |', '|---|---|---|---|'
    $md += @($rec.Policies) | Sort-Object Key, Name | ForEach-Object { "| ``$($_.Key)`` | $(& $esc $_.Name) | $($_.Kind) | $(& $esc (& $fmt $_.Kind $_.Data)) |" }

    $md += '', '## 9. Named settings at default', '',
           'The registry values behind each named setting that was at its default. Import writes them only with `OverwriteChangedSettings` (fixed Windows defaults that were changed on the new PC) or `ApplyDeviceDefaults` (defaults that vary by PC). "(missing)" means the value is deleted.', '',
           '| Category | Setting | Value | Default kind | Registry values |', '|---|---|---|---|---|'
    $md += foreach ($d in $defaults) {
        $regs = @($d.Values) | ForEach-Object { '`' + "$($_.Key)\$($_.Name)" + '` = ' + $(if ($_.Missing) { '(missing)' } else { & $esc (& $fmt $_.Kind $_.Data) }) }
        "| $($d.Cat) | $($d.Name) | $(& $esc $d.Value) | $(if ($d.Device) { 'Varies by PC' } else { 'Windows' }) | $($regs -join '<br>') |"
    }

    $md | Set-Content "$Path\CHANGES_LONG.md" -Encoding UTF8
}

# WinRT helpers for the lock screen image (no admin needed)
function Initialize-WinRT {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
}
function Wait-WinRT($op, [type]$type) {
    $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $t = $m.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait() | Out-Null; $t.Result
}
function Wait-WinRTAction($op) {
    $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
    $m.Invoke($null, @($op)).Wait() | Out-Null
}

# ================= Export =================
if ($Mode -eq 'Export') {
    # Start clean so settings reset since the last export don't linger. Refuse to wipe a folder that isn't a backup.
    if (Test-Path $Path) {
        if (Test-Path "$Path\source-profile.txt") { Remove-Item $Path -Recurse -Force }
        elseif (Get-ChildItem $Path -Force) { throw "$Path exists and isn't a settings backup. Pick an empty folder." }
    }
    New-Item -ItemType Directory -Force -Path "$Path\files" | Out-Null

    Write-Host 'Comparing your settings with the Default user profile...'
    $hive = Mount-DefaultHive
    $user = @()
    if ($hive -notlike '!*') {
        try { $user = @(Get-UserChanges $hive) } finally { Dismount-DefaultHive }
        Write-Host "  $($user.Count) found by comparing with the template"
    } else {
        Write-Warning "$($hive.Substring(1)) Saving every user value instead of only your changes. $(if (-not $IsAdmin) { 'Run Run-Export.bat and click Yes for a changes-only backup.' })"
        $hive = $null
        $user = @(Get-UserChanges $null)
    }
    # The registry values behind every named setting you changed, in case the area rules dropped them
    $rows = @(Get-SettingRows)
    $have = @{}; foreach ($v in $user) { $have["$($v.Key)|$($v.Name)"] = $true }
    $added = 0
    foreach ($r in $rows) {
        if ($null -eq $r.Default -or $r.Value -eq $r.Default) { continue }
        foreach ($s in $r.Sources) {
            $key, $name = $s -split '\|', 2
            if ($key -notlike 'HKCU\*' -or $name -match $SkipValues) { continue }
            if ($name -eq '(default)') { $name = '' }
            if ($have.ContainsKey("$key|$name")) { continue }
            $val = Read-RegValues $key @($name)
            if ($val) { $user += $val | Select-Object @{ n = 'Area'; e = { 'Named' } }, Key, Name, Kind, Data, @{ n = 'Template'; e = { $null } }, @{ n = 'Reason'; e = { "Behind the named setting '$($r.Cat) > $($r.Name)'" } }; $have["$key|$name"] = $true; $added++ }
        }
    }
    if ($hive) { Write-Host "  + $added behind named settings you changed = $($user.Count) saved" }
    Save-Json @($user) "$Path\values.json"

    # Named settings still at their default, with the registry values behind them (or a note that a value was missing).
    # Import uses these only with OverwriteChangedSettings or ApplyDeviceDefaults.
    $atDefault = foreach ($r in $rows) {
        if ($null -eq $r.Default -or $r.Value -ne $r.Default -or (Test-NoReset $r)) { continue }
        $vals = foreach ($s in $r.Sources) {
            $key, $name = $s -split '\|', 2
            if ($name -match $SkipValues) { continue }
            if ($name -eq '(default)') { $name = '' }
            $v = Read-RegValues $key @($name)
            if ($v) { $v } else { [pscustomobject]@{ Key = $key; Name = $name; Missing = $true } }
        }
        if ($vals) { [pscustomobject]@{ Cat = $r.Cat; Name = $r.Name; Value = $r.Value; Device = $r.Device; Values = @($vals) } }
    }
    Save-Json @($atDefault) "$Path\defaults.json"
    Write-Host "Named settings at default: $(@($atDefault).Count) recorded ($(@($atDefault | Where-Object Device).Count) vary by PC)"

    $machine = @(Get-MachineChanges)
    Save-Json @($machine) "$Path\machine.json"
    Write-Host "Machine-wide: $($machine.Count) changed"

    Write-Host 'Recording services, scheduled tasks, optional features, policies...'
    $recorded = Get-Recorded
    Save-Json $recorded "$Path\recorded.json"

    $pw = Get-PowerSettings
    $pwChanges = @(Get-PowerChanges $pw)
    Save-Json ([ordered]@{ Scheme = $pw.Scheme; SchemeName = $pw.SchemeName; Settings = $pwChanges }) "$Path\power.json"
    Write-Host "Power plan: $($pwChanges.Count) changed"

    Save-Json ([ordered]@{
        TimeZone           = (tzutil /g)
        Languages          = @(foreach ($l in (Get-WinUserLanguageList)) { [ordered]@{ Tag = $l.LanguageTag; Inputs = @($l.InputMethodTips) } })
        SystemLocale       = (Get-WinSystemLocale).Name
        HibernateAvailable = [bool](Get-HibernateAvailable)
        HostsEntries       = @(Get-HostsEntries)
    }) "$Path\system.json"

    # Files: custom wallpaper and lock screen, Start pins, taskbar pins, Quick access pins
    $wp = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper
    if ($wp -and $wp -notlike '*\Windows\Web\Wallpaper\*' -and (Test-Path -LiteralPath $wp)) {
        Copy-Item -LiteralPath $wp "$Path\files\wallpaper$([IO.Path]::GetExtension($wp))" -Force
        Write-Host "Copied wallpaper: $wp"
    }
    if ((Get-Reg "$CV\ContentDeliveryManager" RotatingLockScreenEnabled) -eq 0) {
        try {
            Initialize-WinRT
            $src = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead([Windows.System.UserProfile.LockScreen]::GetImageStream())
            $dst = [IO.File]::Create("$Path\files\lockscreen.jpg"); $src.CopyTo($dst); $dst.Close(); $src.Close()
            Write-Host 'Copied lock screen picture'
        } catch { Write-Warning "Couldn't read the lock screen picture: $($_.Exception.Message)" }
    }
    if (Test-Path "$StartPinsDir\start2.bin") { Copy-Item "$StartPinsDir\start*.bin" "$Path\files\" -Force; Write-Host 'Copied Start menu pins' }
    if (Test-Path $PinnedDir) { Copy-Item $PinnedDir "$Path\files\UserPinned" -Recurse -Force; Write-Host "Copied taskbar pins: $((Get-TaskbarPins) -join ', ')" }
    if (Test-Path $QuickAccess) { Copy-Item $QuickAccess "$Path\files\quickaccess.bin" -Force; Write-Host 'Copied Quick access pins' }

    $env:USERPROFILE | Set-Content "$Path\source-profile.txt"
    Save-Json ([ordered]@{ Computer = $env:COMPUTERNAME; Date = (Get-Date -Format 'yyyy-MM-dd h:mm tt'); Baseline = [bool]$hive }) "$Path\meta.json"

    # Named settings: save only changed ones and ones with no fixed default
    Save-Json @($rows | Where-Object { $null -eq $_.Default -or $_.Value -ne $_.Default }) "$Path\settings.json"
    $n = Write-ChangesReport $rows "$Path\CHANGES.md" $user $machine $recorded ([bool]$hive)
    Write-Host "Wrote CHANGES.md ($n named settings changed from default)"
    Write-LongReport $Path
    Write-Host 'Wrote CHANGES_LONG.md (every saved change in full detail)'

    Write-Host "`nDone. Backup is in: $Path" -ForegroundColor Green
    return
}


# ================= Diff (read-only) =================
if ($Mode -eq 'Diff') {
    if (-not (Test-Path "$Path\recorded.json")) { throw "No backup found at $Path, or it was made by an older version of this tool. Run Export first." }
    $meta = Get-Content "$Path\meta.json" -Raw | ConvertFrom-Json
    $oldProfile = (Get-Content "$Path\source-profile.txt" | Select-Object -First 1)
    $out = Join-Path $ScriptDir 'DIFF.md'
    $trim = { param($s) $s = "$s"; if ($s.Length -gt 60) { $s.Substring(0, 57) + '...' } else { $s } }

    Write-Host 'Reading current settings...'
    # Named settings. The backup only holds changed ones, so a missing row means "was at default".
    # defaults.json has the ones at default, so the backup's real value is known even where defaults vary by PC
    $backup = @{}; foreach ($b in @(Read-JsonArray "$Path\settings.json") + @(Read-JsonArray "$Path\defaults.json")) { $backup["$($b.Cat)|$($b.Name)"] = $b }
    $named = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    # Options the redesigned Start menu dropped. Import still copies them, but a difference there isn't one you'd see.
    $OlderStartOnly = @('Start|Layout'); $olderStart = @()
    foreach ($l in Get-SettingRows) {
        $id = "$($l.Cat)|$($l.Name)"; $seen[$id] = $true
        $bv = if ($backup.ContainsKey($id)) { $backup[$id].Value } elseif ($null -ne $l.Default) { $l.Default } else { '(not in backup)' }
        if ($bv -ne $l.Value -and $id -in $OlderStartOnly) { $olderStart += "$($l.Name) (backup: $bv, this PC: $($l.Value))" }
        elseif ($bv -ne $l.Value) {
            $isDef =if ($null -eq $l.Default) { 'n/a' } elseif ($l.Device) { 'Varies by PC' } elseif ($l.Value -eq $l.Default) { 'Yes' } else { 'No' }
            $named.Add([pscustomobject]@{ Category = $l.Cat; Setting = $l.Name; Backup = $bv; Current = $l.Value; Default = $isDef })
        }
    }
    foreach ($id in $backup.Keys) {
        if (-not $seen.ContainsKey($id)) { $b = $backup[$id]; $named.Add([pscustomobject]@{ Category = $b.Cat; Setting = $b.Name; Backup = $b.Value; Current = '(not on this PC)'; Default = 'n/a' }) }
    }

    # Every other saved user value, compared with what this PC has now
    $raw = New-Object System.Collections.Generic.List[object]
    $prof = { param($s) $s = "$s"; if ($oldProfile) { $s = $s.Replace($oldProfile, '%USERPROFILE%') }; $s.Replace($env:USERPROFILE, '%USERPROFILE%') }
    foreach ($v in @(Read-JsonArray "$Path\values.json")) {
        if ($NoisyAreas -contains $v.Area -or (Test-PolicyCovers $v)) { continue }
        $k = Open-RegKey $v.Key
        $cur = if ($k) { $d = $k.GetValue($v.Name, $null, 'DoNotExpandEnvironmentNames'); $k.Close(); if ($null -ne $d) { & $prof (Norm $d) } } else { $null }
        $bk = & $prof (Norm $v.Data)
        # CloudStore copies always differ by their timestamp, so compare them without it
        if ($cur -and $v.Key -like '*\CloudStore\Store\*' -and $v.Kind -eq 'Binary') { $cur = Update-CloudStoreStamp $cur 0; $bk = Update-CloudStoreStamp $bk 0 }
        if ($bk -ne $cur) { $raw.Add([pscustomobject]@{ Value = "$($v.Area): $($v.Key.Substring(5))\$($v.Name)"; Backup = (& $trim $bk); Current = (& $trim (Or $cur '(missing)')) }) }
    }
    # Machine-wide values with defaults
    $mb = @{}; foreach ($v in @(Read-JsonArray "$Path\machine.json")) { $mb["$($v.Key)\$($v.Name)"] = "$($v.Data)" }
    foreach ($m in Get-MachineList) {
        if ($m.OnlyIf -and -not (& $m.OnlyIf)) { continue }
        $id = "$($m.Key)\$($m.Name)"
        $cur = Or (Or (Read-RegValues $m.Key @($m.Name)).Data $m.Missing) $(if ($m.Default -eq '*') { '(missing)' } else { $m.Default })
        $bv = if ($mb.ContainsKey($id)) { $mb[$id] } elseif ($m.Default -eq '*') { '(missing)' } else { "$($m.Default)" }
        if ("$cur" -ne $bv) { $raw.Add([pscustomobject]@{ Value = "Machine: $id"; Backup = (Format-MachineValue $m.Name $bv); Current = (Format-MachineValue $m.Name $cur) }) }
    }

    # Recorded items
    $rec = Get-Content "$Path\recorded.json" -Raw | ConvertFrom-Json
    $live = Get-Recorded
    $recDiff = New-Object System.Collections.Generic.List[object]
    $ls = @{}; foreach ($s in $live.Services) { $ls[$s.Name] = Format-Start $s }
    foreach ($s in $rec.Services) { $b = Format-Start $s; $c = Or $ls[$s.Name] '(not on this PC)'; if ($b -ne $c) { $recDiff.Add([pscustomobject]@{ Item = "Service: $($s.Name)"; Backup = $b; Current = $c }) } }
    $lt = @($live.DisabledTasks)
    # Without admin, Windows hides some tasks entirely. Only compare tasks this session can see.
    $visible = @{}; foreach ($x in @(Get-ScheduledTask -TaskPath '\Microsoft\*' -EA SilentlyContinue)) { $visible["$($x.TaskPath)$($x.TaskName)"] = $true }
    $hiddenTasks = 0
    foreach ($t in @($rec.DisabledTasks)) {
        if ($lt -contains $t) { continue }
        if (-not $visible.ContainsKey($t)) { $hiddenTasks++; continue }
        $recDiff.Add([pscustomobject]@{ Item = "Task: $t"; Backup = 'Disabled'; Current = 'Enabled' })
    }
    foreach ($t in $lt) { if (@($rec.DisabledTasks) -notcontains $t) { $recDiff.Add([pscustomobject]@{ Item = "Task: $t"; Backup = 'Enabled'; Current = 'Disabled' }) } }
    $lf = @{}; foreach ($f in $live.Features) { $lf[$f.Name] = $f.Enabled }
    foreach ($f in $rec.Features) { if ($lf.ContainsKey($f.Name) -and $lf[$f.Name] -ne $f.Enabled) { $recDiff.Add([pscustomobject]@{ Item = "Feature: $($f.Name)"; Backup = (OnOff $f.Enabled); Current = (OnOff $lf[$f.Name]) }) } }
    $lp = @{}; foreach ($p in $live.Policies) { $lp["$($p.Key)\$($p.Name)"] = Norm $p.Data }
    $bp = @{}; foreach ($p in $rec.Policies) { $bp["$($p.Key)\$($p.Name)"] = Norm $p.Data }
    foreach ($id in (@($bp.Keys) + @($lp.Keys) | Sort-Object -Unique)) {
        if ($bp[$id] -ne $lp[$id]) { $recDiff.Add([pscustomobject]@{ Item = "Policy: $id"; Backup = (& $trim (Or $bp[$id] '(missing)')); Current = (& $trim (Or $lp[$id] '(missing)')) }) }
    }

    $esc = { param($s) "$s" -replace '\|', '\|' }
    $md = @('# Settings diff', '',
            "Backup from **$($meta.Computer)** ($($meta.Date)) compared with **$env:COMPUTERNAME** on $(Get-Date -Format 'yyyy-MM-dd h:mm tt'). Nothing was changed.", '',
            '**Default** = is the current value the Windows default? (n/a = no fixed default; Varies by PC = Windows picks it per PC, and Import copies the old PC''s only with `ApplyDeviceDefaults`)', '')
    $target = Get-TargetName $meta
    $md += "**PC name:** $(if (-not $target) { "Import leaves it as **$env:COMPUTERNAME** (``ComputerName`` isn't set)." } elseif (-not (Test-PcName $target)) { "``ComputerName`` gives **$target**, which isn't a valid PC name, so Import would skip it." } elseif ($target -ieq $env:COMPUTERNAME) { "already **$target**." } else { "Import would rename **$env:COMPUTERNAME** to **$target**." })", ''
    if ($named.Count) {
        $md += "## $($named.Count) named settings differ", '', '| Category | Setting | Backup | Current | Default |', '|---|---|---|---|---|'
        $md += $named | ForEach-Object { "| $($_.Category) | $($_.Setting) | $($_.Backup) | $($_.Current) | $($_.Default) |" }
    } else { $md += '## All named settings match the backup' }
    if ($olderStart) { $md += '', "Also different, but only the older Start menu has these options, so they do nothing with the redesigned Start: Start > $($olderStart -join '; ')." }
    $md += '', "## $($raw.Count) other saved values differ", '', 'Values the backup restores that don''t have simple labels. Folder views are left out because they change every time you browse.', ''
    if ($raw.Count) {
        $md += '| Value | Backup | Current |', '|---|---|---|'
        $md += $raw | Select-Object -First 300 | ForEach-Object { "| ``$($_.Value)`` | $(& $esc $_.Backup) | $(& $esc $_.Current) |" }
        if ($raw.Count -gt 300) { $md += '', "...and $($raw.Count - 300) more." }
    }
    $md += '', "## $($recDiff.Count) recorded items differ", '', 'Services, scheduled tasks, optional features, and machine policies. Import only applies these with `-IncludeRecorded`.', ''
    if ($hiddenTasks) { $md += "$hiddenTasks scheduled tasks in the backup aren't visible without admin, so they weren't compared.", '' }
    if ($recDiff.Count) {
        $md += '| Item | Backup | Current |', '|---|---|---|'
        $md += $recDiff | ForEach-Object { "| ``$($_.Item)`` | $(& $esc $_.Backup) | $(& $esc $_.Current) |" }
    }
    $md | Set-Content $out -Encoding UTF8

    if ($named.Count) { $named | Format-Table Category, Setting, Backup, Current, Default -AutoSize -Wrap | Out-String -Width 200 | Write-Host }
    else { Write-Host "`nAll named settings match the backup." -ForegroundColor Green }
    Write-Host "$($raw.Count) other saved values and $($recDiff.Count) recorded items differ (listed in DIFF.md)."
    Write-Host "`nFull report: $out" -ForegroundColor Green
    return
}

# ================= Import =================
if (-not (Test-Path "$Path\recorded.json")) { throw "No backup found at $Path, or it was made by an older version of this tool. Run Export on the old PC first." }

$oldProfile = (Get-Content "$Path\source-profile.txt" -EA 0 | Select-Object -First 1)
$newProfile = $env:USERPROFILE
function Fix-Profile($s) { if ($oldProfile -and $oldProfile -ne $newProfile -and $s -is [string]) { $s.Replace($oldProfile, $newProfile) } else { $s } }

# Explorer and Start hold some of these files open and rewrite them on exit, so stop them first
Stop-Process -Name explorer -Force -EA SilentlyContinue
Stop-Process -Name StartMenuExperienceHost -Force -EA SilentlyContinue
Start-Sleep -Seconds 1

$ok = 0; $failed = @(); $cloudWritten = @()
foreach ($v in @(Read-JsonArray "$Path\values.json")) {
    if ($v.Key -like '*\Taskband') { continue }   # the taskbar pin list goes in with its shortcut files, below
    if (Test-PolicyCovers $v) { continue }
    if ($v.Key -like '*\CloudStore\Store\*' -and $v.Kind -eq 'Binary') { $v.Data = Update-CloudStoreStamp $v.Data; $cloudWritten += $v }
    if ($v.Kind -in 'String', 'ExpandString') { $v.Data = Fix-Profile $v.Data }
    if ($v.Kind -eq 'MultiString') { $v.Data = @($v.Data | ForEach-Object { Fix-Profile $_ }) }
    if ($v.Key -eq 'HKCU\Environment') {
        if ($v.Name -like 'OneDrive*') { continue }   # OneDrive sets these itself
        if ($v.Name -eq 'Path') {
            # Merge instead of replace, so this PC's own entries survive
            $mine = @((Read-RegValues 'HKCU\Environment' @('Path')).Data -split ';' | Where-Object { $_ })
            $extra = @($v.Data -split ';' | Where-Object { $_ -and ($mine -notcontains $_) })
            $v.Data = ($mine + $extra) -join ';'
        }
    }
    if ($v.Key -like '*User Shell Folders' -and -not (Test-Path ([Environment]::ExpandEnvironmentVariables($v.Data)))) {
        Write-Warning "Skipped folder location $($v.Name): $($v.Data) doesn't exist here"; continue
    }
    try { Write-RegValue $v; $ok++ } catch { $failed += Format-WriteFailure $v $_ }
}
Write-Host "User settings: $ok values applied"
if ($failed) { Write-Warning "Couldn't set $($failed.Count) values:`n  $($failed -join "`n  ")" }

# Named settings the old PC had at their default. Ones with a fixed Windows default are written only with OverwriteChangedSettings,
# which undoes changes made on this PC.
# Defaults that vary by PC (search box, Widgets, setup privacy choices) are copied only with ApplyDeviceDefaults.
$overwriteChanged = Get-ConfigBool 'OverwriteChangedSettings' $false
$applyDevice = Get-ConfigBool 'ApplyDeviceDefaults' $true
if (($overwriteChanged -or $applyDevice) -and -not (Test-Path "$Path\defaults.json")) {
    Write-Warning 'This backup has no defaults.json (an older version made it), so OverwriteChangedSettings and ApplyDeviceDefaults were skipped. Re-run the export on the old PC.'
} elseif ($overwriteChanged -or $applyDevice) {
    $now = @{}; foreach ($r in Get-SettingRows) { $now["$($r.Cat)|$($r.Name)"] = $r.Value }
    $set = @(); $blocked = @(); $needAdmin = @()
    foreach ($d in @(Read-JsonArray "$Path\defaults.json")) {
        if (-not $(if ($d.Device) { $applyDevice } else { $overwriteChanged })) { continue }
        if ($now["$($d.Cat)|$($d.Name)"] -eq $d.Value) { continue }   # this PC already matches
        if (-not $IsAdmin -and @($d.Values | Where-Object { $_.Key -like 'HKLM\*' })) { $needAdmin += $d.Name; continue }
        try {
            foreach ($v in @($d.Values)) {
                if (-not $v.Missing) { Write-RegValue $v; continue }
                if (-not (Test-RegKey $v.Key)) { continue }
                $k = Open-RegKey $v.Key $true; $k.DeleteValue([string]$v.Name, $false); $k.Close()
            }
            $set += "$($d.Name) ($($d.Value))"
        } catch { $blocked += Format-WriteFailure $v $_ }
    }
    $which = (@($(if ($overwriteChanged) { 'overwrite changed' }), $(if ($applyDevice) { 'old PC' })) | Where-Object { $_ }) -join ' and '
    Write-Host "Defaults ($which): $(if ($set) { "$($set.Count) set: $($set -join ', ')" } else { 'nothing to change' })"
    if ($blocked) { Write-Warning "Couldn't set:`n  $($blocked -join "`n  ")" }
    if ($needAdmin) { Write-Warning "Skipped without admin: $($needAdmin -join ', ')" }
}

# Pins and Quick access
if (Test-Path "$Path\files\start2.bin") { New-Item -ItemType Directory -Force $StartPinsDir | Out-Null; Copy-Item "$Path\files\start*.bin" $StartPinsDir -Force; Write-Host 'Restored Start menu pins' }
if ((Test-Path "$Path\files\UserPinned") -and -not (Get-ConfigBool 'DeleteExistingPins' $true)) {
    Write-Host "Taskbar pins: kept this PC's (DeleteExistingPins is off)"
} elseif (Test-Path "$Path\files\UserPinned") {
    # Windows restarts Explorer a second after it's stopped, and a running Explorer overwrites the pin list
    # with its own. Stop it again right before writing so the backup's pins are what it reads on the restart.
    Stop-Process -Name explorer -Force -EA SilentlyContinue
    for ($i = 0; $i -lt 20 -and (Get-Process explorer -EA SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
    # Clear this PC's pins: its shortcut files and the pin list that points at them
    Get-ChildItem -LiteralPath $PinnedDir -Recurse -Filter *.lnk -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    $k = Open-RegKey "$CV\Explorer\Taskband" $true
    foreach ($n in $k.GetValueNames()) { $k.DeleteValue($n, $false) }
    $k.Close()
    # Restore a pin only if its app is on this PC. Windows drops pins whose shortcut is missing, so no blank icons.
    $shell = New-Object -ComObject WScript.Shell
    $restored = @(); $missing = @()
    foreach ($lnk in Get-ChildItem "$Path\files\UserPinned" -Recurse -Filter *.lnk) {
        $target = [Environment]::ExpandEnvironmentVariables($shell.CreateShortcut($lnk.FullName).TargetPath)
        if ($target -and -not (Test-Path -LiteralPath $target)) { $missing += $lnk.BaseName; continue }
        $dest = Join-Path $PinnedDir $lnk.FullName.Substring("$Path\files\UserPinned".Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath $lnk.FullName $dest -Force
        $restored += $lnk.BaseName
    }
    # Then the pin list, now that the shortcuts it points at are in place
    foreach ($v in @(Read-JsonArray "$Path\values.json" | Where-Object { $_.Key -like '*\Taskband' })) {
        try { Write-RegValue $v } catch { Write-Warning "Couldn't write the taskbar pin list: $(Format-WriteFailure $v $_)" }
    }
    # Store app pins live in the pin list itself; just report the ones not installed
    $fav = @(Read-JsonArray "$Path\values.json" | Where-Object { $_.Key -like '*\Taskband' -and $_.Name -eq 'Favorites' })[0]
    if ($fav) {
        $pkgs = [regex]::Matches([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($fav.Data)), 'WindowsApps\\([^_\\]+)_') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        foreach ($p in $pkgs) { if (Get-AppxPackage -Name $p -EA SilentlyContinue) { $restored += $p } else { $missing += $p } }
    }
    Write-Host "Taskbar pins restored: $($restored -join ', ')"
    if ($missing) { Write-Warning "Not pinned because the app isn't installed: $($missing -join ', '). Install it and pin it by hand." }
}
if (Test-Path "$Path\files\quickaccess.bin") { Copy-Item "$Path\files\quickaccess.bin" $QuickAccess -Force; Write-Host 'Restored Quick access pins' }

# Wallpaper: copy somewhere permanent and apply now
$wpFile = Get-ChildItem "$Path\files" -Filter 'wallpaper.*' | Select-Object -First 1
if ($wpFile) {
    $wpDir = Join-Path $env:USERPROFILE 'Pictures\Wallpapers'
    New-Item -ItemType Directory -Force -Path $wpDir | Out-Null
    $newWp = Join-Path $wpDir $wpFile.Name
    Copy-Item $wpFile.FullName $newWp -Force
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' WallPaper $newWp
    Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
    [Win32.Native]::SystemParametersInfo(0x0014, 0, $newWp, 0x03) | Out-Null   # SPI_SETDESKWALLPAPER, save + broadcast
    Write-Host "Wallpaper set: $newWp"
}
if (Test-Path "$Path\files\lockscreen.jpg") {
    try {
        $lsPath = Join-Path $env:USERPROFILE 'Pictures\Wallpapers\lockscreen.jpg'
        New-Item -ItemType Directory -Force (Split-Path $lsPath) | Out-Null
        Copy-Item "$Path\files\lockscreen.jpg" $lsPath -Force
        Initialize-WinRT
        $sf = Wait-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($lsPath)) ([Windows.Storage.StorageFile])
        Wait-WinRTAction ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($sf))
        Write-Host 'Lock screen picture set'
    } catch { Write-Warning "Couldn't set the lock screen picture: $($_.Exception.Message)" }
}

# Power plan: same plan if this PC has it, then only the values you changed
$pw = Get-Content "$Path\power.json" -Raw | ConvertFrom-Json
if ((powercfg /list | Out-String) -match $pw.Scheme) { powercfg /setactive $pw.Scheme | Out-Null }
$applied = 0
foreach ($s in @($pw.Settings)) {
    if ($null -ne $s.AC) { powercfg /setacvalueindex SCHEME_CURRENT $s.Sub $s.Guid $s.AC 2>$null | Out-Null; $applied++ }
    if ($null -ne $s.DC) { powercfg /setdcvalueindex SCHEME_CURRENT $s.Sub $s.Guid $s.DC 2>$null | Out-Null; $applied++ }
}
powercfg /setactive SCHEME_CURRENT | Out-Null
Write-Host "Power plan: $applied values applied"

# Time zone and languages
$sys = Get-Content "$Path\system.json" -Raw | ConvertFrom-Json
if ((tzutil /g) -ne $sys.TimeZone) { tzutil /s $sys.TimeZone; Write-Host "Time zone set: $($sys.TimeZone)" }
try {
    $list = New-WinUserLanguageList $sys.Languages[0].Tag
    $list[0].InputMethodTips.Clear(); $sys.Languages[0].Inputs | ForEach-Object { $list[0].InputMethodTips.Add($_) }
    foreach ($l in @($sys.Languages | Select-Object -Skip 1)) {
        $list.Add($l.Tag); $list[$list.Count - 1].InputMethodTips.Clear()
        $l.Inputs | ForEach-Object { $list[$list.Count - 1].InputMethodTips.Add($_) }
    }
    Set-WinUserLanguageList $list -Force -WarningAction SilentlyContinue
    Write-Host "Languages and keyboards set: $(($sys.Languages | ForEach-Object Tag) -join ', ')"
} catch { Write-Warning "Couldn't set languages: $($_.Exception.Message)" }

# Machine-wide settings need admin
if ($IsAdmin) {
    $n = 0
    foreach ($v in @(Read-JsonArray "$Path\machine.json")) { try { Write-RegValue $v; $n++ } catch { Write-Warning "Couldn't set $($v.Key)\$($v.Name)" } }
    Write-Host "Machine-wide: $n values applied"
    # The sign-in screen takes Num Lock from the system profile, not yours, so copy your Num Lock bit there too
    $nl = Get-Reg 'HKCU\Control Panel\Keyboard' InitialKeyboardIndicators
    if ($null -ne $nl) {
        try {
            $sysKb = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'
            $cur = [int64](Or (Get-ItemProperty -LiteralPath $sysKb -EA SilentlyContinue).InitialKeyboardIndicators 0)
            $new = ($cur -band -bnot 2) -bor ([int64]$nl -band 2)
            if ($new -ne $cur) { Set-ItemProperty -LiteralPath $sysKb InitialKeyboardIndicators "$new"; Write-Host "Num Lock on the sign-in screen: $(OnOff ($new -band 2))" }
        } catch { Write-Warning "Couldn't set Num Lock for the sign-in screen: $(Get-ErrorText $_)" }
    }
    if ($sys.HibernateAvailable -ne [bool](Get-HibernateAvailable)) { powercfg /hibernate $(if ($sys.HibernateAvailable) { 'on' } else { 'off' }) }
    if ((Get-WinSystemLocale).Name -ne $sys.SystemLocale) { Set-WinSystemLocale $sys.SystemLocale; Write-Host "System locale set to $($sys.SystemLocale) (needs a restart)" }
    $have = @(Get-HostsEntries)
    $add = @($sys.HostsEntries | Where-Object { $_ -and $have -notcontains $_ })
    if ($add.Count) {
        Copy-Item $HostsFile "$HostsFile.bak-winsettings" -Force
        Add-Content $HostsFile (@('', '# Added by WindowsSettings import') + $add) -Encoding ASCII
        Write-Host "Hosts file: $($add.Count) entries added (backup at hosts.bak-winsettings)"
    }

    if ($IncludeRecorded) {
        $rec = Get-Content "$Path\recorded.json" -Raw | ConvertFrom-Json
        $live = Get-Recorded
        $ls = @{}; foreach ($s in $live.Services) { $ls[$s.Name] = $s }
        $c = 0
        foreach ($s in $rec.Services) {
            $l = $ls[$s.Name]
            if (-not $l -or ($l.Start -eq $s.Start -and $l.Delayed -eq $s.Delayed)) { continue }
            try {
                Write-RegValue ([pscustomobject]@{ Key = "HKLM\SYSTEM\CurrentControlSet\Services\$($s.Name)"; Name = 'Start'; Kind = 'DWord'; Data = $s.Start })
                Write-RegValue ([pscustomobject]@{ Key = "HKLM\SYSTEM\CurrentControlSet\Services\$($s.Name)"; Name = 'DelayedAutostart'; Kind = 'DWord'; Data = $s.Delayed })
                $c++
            } catch { Write-Warning "Couldn't change service $($s.Name)" }
        }
        Write-Host "Services: $c startup types changed"
        $c = 0
        foreach ($t in @($rec.DisabledTasks)) {
            if (@($live.DisabledTasks) -contains $t) { continue }
            $tp = $t.Substring(0, $t.LastIndexOf('\') + 1); $tn = $t.Substring($t.LastIndexOf('\') + 1)
            if (Get-ScheduledTask -TaskPath $tp -TaskName $tn -EA SilentlyContinue) { try { Disable-ScheduledTask -TaskPath $tp -TaskName $tn | Out-Null; $c++ } catch { } }
        }
        Write-Host "Scheduled tasks: $c disabled"
        $lf = @{}; foreach ($f in $live.Features) { $lf[$f.Name] = $f.Enabled }
        foreach ($f in $rec.Features) {
            if (-not $lf.ContainsKey($f.Name) -or $lf[$f.Name] -eq $f.Enabled) { continue }
            try {
                if ($f.Enabled) { Enable-WindowsOptionalFeature -Online -FeatureName $f.Name -All -NoRestart -WarningAction SilentlyContinue | Out-Null; Write-Host "Feature on: $($f.Name)" }
                else { Disable-WindowsOptionalFeature -Online -FeatureName $f.Name -NoRestart -WarningAction SilentlyContinue | Out-Null; Write-Host "Feature off: $($f.Name)" }
            } catch { Write-Warning "Couldn't change feature $($f.Name)" }
        }
        $c = 0
        foreach ($p in @($rec.Policies)) { try { Write-RegValue $p; $c++ } catch { } }
        Write-Host "Machine policies: $c values applied"
    }

    # PC name, only when ComputerName asks for it
    $target = Get-TargetName (Get-Content "$Path\meta.json" -Raw | ConvertFrom-Json)
    if ($target) {
        if (-not (Test-PcName $target)) { Write-Warning "ComputerName gives '$target', which isn't a valid PC name (1-15 letters, digits or hyphens, not only digits). Left the name as $env:COMPUTERNAME." }
        elseif ($target -ieq $env:COMPUTERNAME) { Write-Host "PC name: already $target" }
        else {
            try { Rename-Computer -NewName $target -Force -WarningAction SilentlyContinue -ErrorAction Stop; Write-Host "PC name: $env:COMPUTERNAME -> $target (after the restart)" }
            catch { Write-Warning "Couldn't rename the PC to ${target}: $($_.Exception.Message)" }
        }
    }
} else {
    Write-Warning "Not running as admin: skipped machine-wide settings (fast startup, hibernate, UAC, AutoPlay policy, Remote Desktop, Windows Update options, location services, system locale, hosts file$(if ($ComputerName) { ', PC name' })). Re-run Run-Import.bat and click Yes."
}

if (-not (Get-Process explorer -EA SilentlyContinue)) { Start-Process explorer }   # Windows may have restarted it already
# Windows can put back its own copy of CloudStore settings, so check they stuck once Explorer is running again
if ($cloudWritten) {
    Start-Sleep -Seconds 5
    $reverted = @($cloudWritten | Where-Object { (Read-RegValues $_.Key @([string]$_.Name)).Data -ne $_.Data })
    if ($reverted) { Write-Warning "Windows put back its own copy of $($reverted.Count) value(s), so set these by hand: $(($reverted | ForEach-Object { if ($_.Area -eq 'NightLight') { 'Night light (Settings > System > Display > Night light)' } else { "$($_.Area) ($($_.Key.Substring(5)))" } }) -join '; ')" }
}
# Newer builds (seen on 26H2) keep Night light strength outside the registry and ignore the value written above
if (@($cloudWritten | Where-Object Area -eq 'NightLight').Count) {
    Write-Host 'Check Night light by hand: newer Windows builds ignore the copied strength and schedule. Match the old PC in Settings > System > Display > Night light.' -ForegroundColor Yellow
}
if ($IsAdmin) { Write-Host "`nDone. Restart the PC so everything fully applies." -ForegroundColor Green }
else { Write-Host "`nDone, but NOT everything was applied: machine-wide settings were skipped because this wasn't run as admin. Run Run-Import.bat and click Yes to finish." -ForegroundColor Yellow }

} catch {
    # Show the error before the window can close
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    $script:Failed = $true
} finally {
    # -AutoClose (the .bat files pass it): count down 5 seconds, P pauses so the window stays open
    if ($AutoClose -and -not $script:Relaunched) {
        Write-Host ''
        $color = if ($script:Failed) { 'Red' } else { 'Yellow' }
        $paused = $false
        for ($i = 5; $i -gt 0 -and -not $paused; $i--) {
            Write-Host -NoNewline "`rThis window closes in $i second$(if ($i -ne 1) { 's' }). Press P to pause.  " -ForegroundColor $color
            $until = (Get-Date).AddSeconds(1)
            while ((Get-Date) -lt $until) {
                try {
                    if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'P') { $paused = $true; break }
                } catch { }   # no console (redirected output): just count down
                Start-Sleep -Milliseconds 100
            }
        }
        if ($paused) {
            Write-Host "`rPaused. Press any key to close.                       " -ForegroundColor Green
            try { [void][Console]::ReadKey($true) } catch { }
        } else { Write-Host '' }
    }
    if ($script:Failed) { exit 1 }
}