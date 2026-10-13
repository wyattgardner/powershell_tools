<#
  WindowsDefaultApps.ps1 - carry your default apps to a fresh Windows 11 install.

  Modes:
    Export   Save the default apps you've changed from Windows' defaults into DefaultAppsBackup, plus CHANGES.md.
    Preview  Read-only. Show what Import would set on this PC, and what it would skip because the app isn't installed.
    Import   Apply them (needs admin). Takes effect at your next sign-in.

  Windows signs default app choices with a per-PC hash and guards browser/PDF choices, so scripts can't write them
  directly. Import uses the supported route instead: Windows' "default associations configuration" policy, which
  applies an XML file at sign-in. A one-time cleanup task removes the policy afterwards so you can still change apps.

  Normally run through Run-Export.bat, Run-Preview.bat, and Run-Import.bat.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Preview', 'Import')][string]$Mode,
    [string]$Path,
    [switch]$Yes,       # Import: skip the confirmation prompt
    [switch]$OnlyMine,  # Preview/Import: apply only your exact choices, without letting apps take over the other types they support
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
if (-not $PSBoundParameters.ContainsKey('OnlyMine')) { $OnlyMine = Get-ConfigBool 'OnlyMine' $false }
if (-not $PSBoundParameters.ContainsKey('Yes')) { $Yes = Get-ConfigBool 'SkipConfirm' $false }
# RunAsAdmin (on by default): reopen this script in an admin window when the mode needs it. Exit code 99 tells the .bat it moved on.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Mode -eq 'Import') -and -not $IsAdmin -and -not $Elevated -and (Get-ConfigBool 'RunAsAdmin' $true)) {
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
}if (-not $Path) { $Path = Join-Path $ScriptDir 'DefaultAppsBackup' }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$FileExts    = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
$UrlAssoc    = 'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations'
$OemFile     = "$env:SystemRoot\System32\OEMDefaultAssociations.xml"
$PolicyKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$PolicyValue = 'DefaultAssociationsConfiguration'
$XmlPath     = "$env:ProgramData\WindowsDefaultApps\associations.xml"
$CleanupTask = 'WindowsDefaultApps-RemovePolicy'

Add-Type -Namespace Win32 -Name Shlwapi -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet=CharSet.Unicode)]
public static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf, int cchOutBuf, System.IntPtr ppvReserved);
'@

# Direct .NET registry access. PowerShell's registry provider is very slow on HKEY_CLASSES_ROOT.
function Open-Key($key) {
    $i = $key.IndexOf('\')
    $root = if ($i -lt 0) { $key } else { $key.Substring(0, $i) }
    $hive = switch ($root) {
        { $_ -in 'HKLM', 'HKEY_LOCAL_MACHINE' } { [Microsoft.Win32.Registry]::LocalMachine }
        { $_ -in 'HKCU', 'HKEY_CURRENT_USER' } { [Microsoft.Win32.Registry]::CurrentUser }
        { $_ -in 'HKCR', 'HKEY_CLASSES_ROOT' } { [Microsoft.Win32.Registry]::ClassesRoot }
    }
    if ($i -lt 0) { return $hive }
    try { $hive.OpenSubKey($key.Substring($i + 1)) } catch { $null }
}
function Get-Reg($key, $name) {
    $k = Open-Key $key
    if (-not $k) { return $null }
    $v = $k.GetValue($(if ($name -eq '(default)') { '' } else { $name }))
    $k.Close(); $v
}
function Get-SubKeyNames($key) { $k = Open-Key $key; if ($k) { $k.GetSubKeyNames(); $k.Close() } }
function Get-ValueMap($key) { $m = @{}; $k = Open-Key $key; if ($k) { foreach ($n in $k.GetValueNames()) { $m[$n] = $k.GetValue($n) }; $k.Close() }; $m }
function Or($v, $d) { if ($null -eq $v -or "$v" -eq '') { $d } else { $v } }
function Test-ProgId($p) { if (-not $p) { return $false }; $k = Open-Key "HKCR\$p"; if ($k) { $k.Close(); $true } else { $false } }

# "@{Microsoft.Photos...?ms-resource://...}" style names -> readable text
function Resolve-Name($s) {
    if ($s -and "$s".StartsWith('@')) {
        $sb = New-Object Text.StringBuilder 1024
        if ([Win32.Shlwapi]::SHLoadIndirectString($s, $sb, 1024, [IntPtr]::Zero) -eq 0) { return $sb.ToString() }
    }
    $s
}

# The app chosen for each file type and link type. UserChoiceLatest is the live one on newer builds.
function Get-Choices {
    foreach ($base in $FileExts, $UrlAssoc) {
        foreach ($id in @(Get-SubKeyNames $base)) {
            $p = Or (Get-Reg "$base\$id\UserChoiceLatest\ProgId" ProgId) (Get-Reg "$base\$id\UserChoice" ProgId)
            if ($p) { [pscustomobject]@{ Identifier = $id.ToLower(); ProgId = $p } }
        }
    }
}

# Windows' out-of-box defaults on this PC
function Get-OemDefaults {
    $m = @{}
    if (Test-Path $OemFile) { foreach ($a in ([xml](Get-Content $OemFile -Raw)).DefaultAssociations.Association) { $m[$a.Identifier.ToLower()] = $a } }
    $m
}

# Every installed app that registers file/link types, and which ProgId it uses for each
function Get-AppIndex {
    $apps = @{}; $byProgId = @{}; $byExe = @{}
    foreach ($hive in 'HKLM', 'HKCU') {
        $ra = Get-ValueMap "$hive\SOFTWARE\RegisteredApplications"
        foreach ($name in $ra.Keys) {
            $cap = "$hive\$($ra[$name])"
            $types = @{}
            foreach ($sub in 'FileAssociations', 'URLAssociations') {
                $m = Get-ValueMap "$cap\$sub"
                foreach ($n in $m.Keys) { $types[$n.ToLower()] = [string]$m[$n] }
            }
            if (-not $types.Count) { continue }
            $key = "reg:$name"
            # Names are resolved only when needed; there can be hundreds of Store apps
            $apps[$key] = [pscustomobject]@{ Key = $key; RawName = (Or (Get-Reg $cap ApplicationName) $name); Name = $null; Types = $types }
            foreach ($p in $types.Values) { if (-not $byProgId.ContainsKey($p)) { $byProgId[$p] = $key } }
            # Desktop apps: remember their program file, to match ProgIds they use but don't list (VLC.mp4.Document, etc.)
            if ($hive -eq 'HKLM') {
                foreach ($p in @($types.Values | Select-Object -First 3)) {
                    $exe = Get-ProgIdExe $p
                    if ($exe -and -not $byExe.ContainsKey($exe)) { $byExe[$exe] = $key }
                }
            }
        }
    }
    [pscustomobject]@{ Apps = $apps; ByProgId = $byProgId; ByExe = $byExe }
}

# A stable identity for the app behind a ProgId, the same on any PC:
# Store apps by their app ID, desktop apps by their registered name, anything else by the ProgId itself
function Get-AppKey($progId, $index) {
    $aumid = Get-Reg "HKCR\$progId\Application" AppUserModelID
    if ($aumid) { return "uwp:$aumid" }
    if ($index.ByProgId.ContainsKey($progId)) { return $index.ByProgId[$progId] }
    $exe = Get-ProgIdExe $progId
    if ($exe -and $index.ByExe.ContainsKey($exe)) { return $index.ByExe[$exe] }
    "progid:$progId"
}
function Get-AppName($progId, $key, $index) {
    if ($index.Apps.ContainsKey($key)) {
        $a = $index.Apps[$key]
        if (-not $a.Name) { $a.Name = Resolve-Name $a.RawName }
        return $a.Name
    }
    $n = Get-Reg "HKCR\$progId\Application" ApplicationName
    if ($n) { return (Resolve-Name $n) }
    # Fall back to the program's own description, e.g. "Microsoft Teams"
    $exe = Get-ProgIdExe $progId
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        $vi = (Get-Item -LiteralPath $exe).VersionInfo
        $d = Or $vi.FileDescription $vi.ProductName
        if ($d) { return $d.Trim() }
    }
    if ($progId -like 'Applications\*') { return $progId.Substring(13) }
    Or (Resolve-Name (Get-Reg "HKCR\$progId" FriendlyTypeName)) $progId
}

# The program a ProgId opens with, as a full lowercase path (or $null)
function Get-ProgIdExe($p) {
    $cmd = [string](Get-Reg "HKCR\$p\shell\open\command" '(default)')
    if (-not $cmd) { return $null }
    $exe = if ($cmd -match '^"([^"]+)"') { $matches[1] } else { ($cmd -split ' ')[0] }
    [Environment]::ExpandEnvironmentVariables($exe).ToLower()
}

# For a ProgId with no registered app, check the program still exists
function Test-ProgIdCommand($p) {
    $exe = Get-ProgIdExe $p
    (-not $exe) -or ($exe -notmatch '\\') -or (Test-Path -LiteralPath $exe)
}

# ================= Export =================
if ($Mode -eq 'Export') {
    Write-Host 'Reading default apps...'
    $oem = Get-OemDefaults
    $index = Get-AppIndex
    $changes = @(foreach ($c in Get-Choices) {
        $d = $oem[$c.Identifier]
        if ($d -and $d.ProgId -eq $c.ProgId) { continue }
        $key = Get-AppKey $c.ProgId $index
        $defKey = if ($d) { Get-AppKey $d.ProgId $index } else { $null }
        if ($defKey -and $defKey -eq $key) { continue }   # same app under a different ProgId isn't a real change
        [pscustomobject]@{
            Identifier = $c.Identifier; ProgId = $c.ProgId; App = $key; AppName = (Get-AppName $c.ProgId $key $index)
            DefaultApp = $defKey; DefaultAppName = $(if ($d) { $d.ApplicationName } else { $null })
        }
    })

    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    ConvertTo-Json -InputObject $changes -Depth 4 | Set-Content "$Path\apps.json" -Encoding UTF8
    ConvertTo-Json -InputObject ([ordered]@{ Computer = $env:COMPUTERNAME; Date = (Get-Date -Format 'yyyy-MM-dd h:mm tt') }) | Set-Content "$Path\meta.json" -Encoding UTF8

    $replacing = @($changes | Where-Object DefaultApp)
    $noDefault = @($changes | Where-Object { -not $_.DefaultApp })
    $md = @('# Default apps changes', '',
            "Exported from **$env:COMPUTERNAME** on $(Get-Date -Format 'yyyy-MM-dd h:mm tt').", '',
            "$($replacing.Count) file and link types use a different app than the Windows default, and $($noDefault.Count) more are set to an app where Windows has no default.", '',
            '## By app', '')
    foreach ($g in ($changes | Group-Object AppName | Sort-Object Count -Descending)) {
        $instead = @($g.Group | Where-Object DefaultAppName | ForEach-Object DefaultAppName | Sort-Object -Unique)
        $md += "### $($g.Name)$(if ($instead.Count) { " (instead of $($instead -join ', '))" })", ''
        $md += (($g.Group | ForEach-Object Identifier | Sort-Object) -join ', '), ''
    }
    $md += '## Changed from the Windows default', '', '| Type | Yours | Windows default |', '|---|---|---|'
    $md += $replacing | Sort-Object Identifier | ForEach-Object { "| $($_.Identifier) | $($_.AppName) | $($_.DefaultAppName) |" }
    $md += '', '## No Windows default', '', 'Windows doesn''t assign these out of the box. You (or an "always use this app" prompt) picked them.', '', '| Type | Yours |', '|---|---|'
    $md += $noDefault | Sort-Object Identifier | ForEach-Object { "| $($_.Identifier) | $($_.AppName) |" }
    $md += '', '## On import', '',
           'Each choice is applied only if that app is installed on the new PC. Apps that replaced a Windows default also take over every other type they support that the replaced app would handle. For example, if Chrome replaced Edge for links, Chrome also gets the other file types Edge would open, as long as Chrome supports them.'
    $md | Set-Content "$Path\CHANGES.md" -Encoding UTF8

    Write-Host "Saved $($changes.Count) default app changes ($($replacing.Count) replacing a Windows default)."
    Write-Host "`nDone. Backup is in: $Path" -ForegroundColor Green
    return
}

# ================= Preview / Import: work out what to set on this PC =================
if (-not (Test-Path "$Path\apps.json")) { throw "No backup found at $Path. Run Export on the old PC first." }
$saved = @(foreach ($x in (Get-Content "$Path\apps.json" -Raw | ConvertFrom-Json)) { $x })

Write-Host 'Checking which apps are installed on this PC...'
$oem = Get-OemDefaults
$index = Get-AppIndex
$current = @{}; foreach ($c in Get-Choices) { $current[$c.Identifier] = $c.ProgId }
function Get-CurrentProgId($id) { Or $current[$id] $(if ($oem[$id]) { $oem[$id].ProgId }) }

# The ProgId this PC uses for that app and type, or $null if the app isn't installed here
function Find-ProgId($s) {
    # Your exact choice, if this PC has it and it belongs to the same app
    if ((Test-ProgId $s.ProgId) -and (Get-AppKey $s.ProgId $index) -eq $s.App -and (Test-ProgIdCommand $s.ProgId)) { return $s.ProgId }
    if ($s.App -like 'reg:*') {
        $app = $index.Apps[$s.App]
        if (-not $app) { return $null }
        $p = $app.Types[$s.Identifier]
        if (Test-ProgId $p) { return $p }
        if ((Test-ProgId $s.ProgId) -and $index.ByProgId[$s.ProgId] -eq $s.App) { return $s.ProgId }
        return $null
    }
    if ($s.App -like 'uwp:*') {
        if ((Test-ProgId $s.ProgId) -and (Get-AppKey $s.ProgId $index) -eq $s.App) { return $s.ProgId }
        return $null
    }
    if ((Test-ProgId $s.ProgId) -and (Test-ProgIdCommand $s.ProgId)) { return $s.ProgId }
    $null
}

$plan = [ordered]@{}
$skipped = New-Object System.Collections.Generic.List[object]
foreach ($s in $saved) {
    $p = Find-ProgId $s
    if ($p) { $plan[$s.Identifier] = [pscustomobject]@{ Identifier = $s.Identifier; ProgId = $p; AppName = $s.AppName; App = $s.App; Why = 'Your choice' } }
    else { $skipped.Add($s) }
}

# Apps that replaced a Windows default also take over the other types they support that the replaced app would get
$replaced = @{}
foreach ($s in $saved) { if ($s.DefaultApp) { if (-not $replaced[$s.App]) { $replaced[$s.App] = @{} }; $replaced[$s.App][$s.DefaultApp] = $s.DefaultAppName } }
foreach ($appKey in @($(if (-not $OnlyMine) { $replaced.Keys }))) {
    $sample = @($plan.Values | Where-Object App -eq $appKey) | Select-Object -First 1
    if (-not $sample) { continue }
    $regKey = $index.ByProgId[$sample.ProgId]
    if (-not $regKey) { continue }
    foreach ($id in $index.Apps[$regKey].Types.Keys) {
        if ($plan.Contains($id)) { continue }
        $cur = Get-CurrentProgId $id
        if (-not $cur) { continue }
        $curKey = Get-AppKey $cur $index
        if ($replaced[$appKey].ContainsKey($curKey)) {
            $p = $index.Apps[$regKey].Types[$id]
            if (Test-ProgId $p) { $plan[$id] = [pscustomobject]@{ Identifier = $id; ProgId = $p; AppName = $sample.AppName; App = $appKey; Why = "Instead of $($replaced[$appKey][$curKey])" } }
        }
    }
}

$todo = @($plan.Values | Where-Object { (Get-CurrentProgId $_.Identifier) -ne $_.ProgId })
$already = $plan.Count - $todo.Count

Write-Host ''
if ($todo.Count) {
    $todo | Sort-Object AppName, Identifier | Format-Table @{ n = 'Type'; e = { $_.Identifier } }, @{ n = 'App'; e = { $_.AppName } }, @{ n = 'Reason'; e = { $_.Why } } -AutoSize | Out-String -Width 200 | Write-Host
}
Write-Host "$($todo.Count) to set, $already already set."
if ($skipped.Count) {
    Write-Host "`nSkipped because the app isn't installed here ($($skipped.Count)):" -ForegroundColor Yellow
    $skipped | Group-Object AppName | ForEach-Object { Write-Host "  $($_.Name): $(($_.Group | ForEach-Object Identifier | Sort-Object) -join ', ')" }
    Write-Host '  Install them and run this again to pick those up.'
}

if ($Mode -eq 'Preview') { Write-Host "`nPreview only. Nothing was changed." -ForegroundColor Green; return }

# ================= Import =================
if (-not $todo.Count) { Write-Host "`nNothing to do." -ForegroundColor Green; return }
if (-not $IsAdmin) { throw 'Import needs admin. Use Run-Import.bat and click Yes.' }
if (-not $Yes) {
    $a = Read-Host "`nApply these $($todo.Count) default apps at your next sign-in? (Y/N)"
    if ($a -notmatch '^(y|yes)$') { Write-Host 'Cancelled. Nothing was changed.'; return }
}

New-Item -ItemType Directory -Force -Path (Split-Path $XmlPath) | Out-Null
$xml = @('<?xml version="1.0" encoding="UTF-8"?>', '<DefaultAssociations>')
$xml += $todo | ForEach-Object { "  <Association Identifier=`"$([Security.SecurityElement]::Escape($_.Identifier))`" ProgId=`"$([Security.SecurityElement]::Escape($_.ProgId))`" ApplicationName=`"$([Security.SecurityElement]::Escape($_.AppName))`" />" }
$xml += '</DefaultAssociations>'
$xml | Set-Content $XmlPath -Encoding UTF8

if (-not (Test-Path $PolicyKey)) { New-Item -Path $PolicyKey -Force | Out-Null }
Set-ItemProperty -Path $PolicyKey -Name $PolicyValue -Value $XmlPath

# Remove the policy a couple of minutes after the next sign-in, so the choices stick but aren't locked in
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"Remove-ItemProperty -Path '$PolicyKey' -Name '$PolicyValue' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName '$CleanupTask' -Confirm:`$false`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = 'PT2M'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskName $CleanupTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

Write-Host "`nDone. Sign out and back in to apply. The temporary policy removes itself a couple of minutes after you sign in." -ForegroundColor Green

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