<#
  WindowsDefaultApps.ps1 - carry your default apps to a fresh Windows 11 install.

  Modes:
    Export   Save the default apps you've changed from Windows' defaults into DefaultAppsBackup, plus CHANGES.md.
    Preview  Read-only. Show what Import would set on this PC, and what it would skip because the app isn't installed.
    Import   Apply them.

  Windows signs default app choices with a per-user hash and guards browser/PDF choices. Import has 3 routes
  (ImportMethod in config):
    Direct  Writes each choice with its UserChoice hash. Only works where UserChoiceLatest is off (see README), and
            never for http, https, or .pdf, which a Windows driver protects. It checks the first write took; if not,
            or for the protected types, it hands over to Guided.
    Guided  Opens each app's Default apps page in Settings, lists the types to set there, and checks them off as
            you go. Works on any PC.
    Policy  Windows' "default associations configuration" policy, which applies an XML file at sign-in (needs admin).
            Windows only honors it for existing accounts on domain-joined PCs; elsewhere it only affects new accounts.
            A one-time cleanup task removes the policy afterwards so you can still change apps.
  Auto (the default) uses Policy on domain-joined PCs and Direct everywhere else.

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
# Import route: Policy only works for existing accounts on domain-joined PCs, so Auto picks Direct everywhere else
# (Direct falls back to Guided by itself when it can't write)
$Method = if ($Config.ImportMethod) { "$($Config.ImportMethod)" } else { 'Auto' }
if ($Method -notin 'Auto', 'Direct', 'Guided', 'Policy') { Write-Warning "ImportMethod '$Method' isn't Auto, Direct, Guided, or Policy. Using Auto."; $Method = 'Auto' }
if ($Method -eq 'Auto') { $Method = if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { 'Policy' } else { 'Direct' } }
# RunAsAdmin (on by default): reopen this script in an admin window when the mode needs it. Exit code 99 tells the .bat it moved on.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Mode -eq 'Import') -and ($Method -eq 'Policy') -and -not $IsAdmin -and -not $Elevated -and (Get-ConfigBool 'RunAsAdmin' $true)) {
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

# The UserChoice hash (the pre-UserChoiceLatest one), plus a key's last-write time, which the hash includes.
# Same algorithm as SetUserFTA and Firefox's default browser agent.
if (-not ('Win32.UserChoice' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
namespace Win32 {
public static class UserChoice {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegQueryInfoKey(Microsoft.Win32.SafeHandles.SafeRegistryHandle hKey, IntPtr c, IntPtr cc, IntPtr r, IntPtr sk, IntPtr msk, IntPtr mc, IntPtr v, IntPtr mvn, IntPtr mvl, IntPtr sd, out long lastWrite);
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);

    public static long LastWrite(Microsoft.Win32.RegistryKey k) {
        long t; RegQueryInfoKey(k.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out t); return t;
    }

    // fileTime: the UserChoice key's last-write time (UTC FILETIME). Only the minute counts.
    public static string Hash(string type, string sid, string progId, long fileTime) {
        long ft = fileTime - (fileTime % 600000000L);
        string ts = ((uint)(ft >> 32)).ToString("x8") + ((uint)ft).ToString("x8");
        string s = (type + sid + progId + ts + "User Choice set via Windows User Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}").ToLowerInvariant();
        byte[] data = Encoding.Unicode.GetBytes(s + "\0");
        byte[] md5 = MD5.Create().ComputeHash(data);
        int n = (data.Length / 4) & ~1;
        uint[] d = new uint[n];
        for (int i = 0; i < n; i++) d[i] = BitConverter.ToUInt32(data, i * 4);
        uint m0 = BitConverter.ToUInt32(md5, 0) | 1, m1 = BitConverter.ToUInt32(md5, 4) | 1;
        uint h1 = 0, s1 = 0, h2 = 0, s2 = 0;
        unchecked {
            uint a = m0 + 0x69FB0000, b = m1 + 0x13DB0000;
            for (int i = 0; i < n; i += 2) {
                uint u = d[i] + h1;
                u = u * a - 0x10FA9605 * (u >> 16);
                u = 0x79F8A395 * u + 0x689B6B9F * (u >> 16);
                uint r = 0xEA970001 * u - 0x3C101569 * (u >> 16);
                u = (r + d[i + 1]) * b - 0x3CE8EC25 * ((r + d[i + 1]) >> 16);
                u = 0x59C3AF2D * u - 0x2232E0F1 * (u >> 16);
                h1 = 0x1EC90001 * u + 0x35BD1EC9 * (u >> 16);
                s1 += r + h1;
            }
            for (int i = 0; i < n; i += 2) {
                uint u = (d[i] + h2) * m0;
                u = 0xB1110000 * u - 0x30674EEF * (u >> 16);
                u = 0x5B9F0000 * u - 0x78F7A461 * (u >> 16);
                u = 0x12CEB96D * (u >> 16) - 0x46930000 * u;
                uint r = 0x1D830000 * u + 0x257E1D83 * (u >> 16);
                u = m1 * (r + d[i + 1]);
                u = 0x16F50000 * u - 0x5D8BE90B * (u >> 16);
                u = 0x96FF0000 * u - 0x2C7C6901 * (u >> 16);
                u = 0x2B890000 * u + 0x7C932B89 * (u >> 16);
                h2 = 0x9F690000 * u - 0x405B6097 * (u >> 16);
                s2 += h2 + r;
            }
        }
        byte[] o = new byte[8];
        BitConverter.GetBytes(h1 ^ h2).CopyTo(o, 0);
        BitConverter.GetBytes(s1 ^ s2).CopyTo(o, 4);
        return Convert.ToBase64String(o);
    }
}
}
'@
}

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

# The app chosen for each file type and link type. UserChoiceLatest is the live one on newer builds, UserChoice
# where that's turned off. Both can be there, so take whichever was written last.
function Get-Choices {
    foreach ($base in $FileExts, $UrlAssoc) {
        foreach ($id in @(Get-SubKeyNames $base)) {
            $best = $null; $bestTime = -1
            foreach ($sub in 'UserChoiceLatest\ProgId', 'UserChoice') {
                $k = Open-Key "$base\$id\$sub"
                if (-not $k) { continue }
                $p = $k.GetValue('ProgId'); $t = [Win32.UserChoice]::LastWrite($k); $k.Close()
                if ($p -and $t -gt $bestTime) { $best = $p; $bestTime = $t }
            }
            if ($best) { [pscustomobject]@{ Identifier = $id.ToLower(); ProgId = $best } }
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
            $apps[$key] = [pscustomobject]@{ Key = $key; RegName = $name; Hive = $hive; RawName = (Or (Get-Reg $cap ApplicationName) $name); Name = $null; Types = $types }
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
Add-Type -Namespace Win32 -Name Assoc -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern int AssocQueryString(int flags, int str, string assoc, string extra, System.Text.StringBuilder outStr, ref uint outLen);
'@
# The app Windows actually uses for a type right now, asked of Windows itself. This reads whichever of
# UserChoice and UserChoiceLatest is live, and falls back to Windows' own default when there's no choice.
function Get-CurrentProgId($id) {
    $sb = New-Object Text.StringBuilder 512; $n = [uint32]512
    $flags = if ($id.StartsWith('.')) { 0 } else { 0x1000 }   # ASSOCF_IS_PROTOCOL for link types like http
    if ([Win32.Assoc]::AssocQueryString($flags, 20, $id, $null, $sb, [ref]$n) -ne 0) { return $null }   # 20 = ASSOCSTR_PROGID
    $p = $sb.ToString()
    if ($p -in 'Unknown', 'Undecided') { $null } else { $p }
}
# Set means this PC already opens the type with that app, even under a different ProgId of the same app
function Test-IsSet($item) {
    $cur = Get-CurrentProgId $item.Identifier
    $cur -and ($cur -eq $item.ProgId -or (Get-AppKey $cur $index) -eq (Get-AppKey $item.ProgId $index))
}

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

$todo = @($plan.Values | Where-Object { -not (Test-IsSet $_) })
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

# The Default apps page in Settings for the app behind a ProgId on this PC
# Store apps by app ID; desktop apps by the name they registered with Windows (Chrome also has an app ID, but
# Settings only finds it by registered name); apps that never registered (VS Code, 7-Zip) get the main page.
function Get-SettingsUri($progId) {
    $aumid = Get-Reg "HKCR\$progId\Application" AppUserModelID
    if ($aumid -like '*!*') { return "ms-settings:defaultapps?registeredAUMID=$([uri]::EscapeDataString($aumid))" }
    $reg = $index.ByProgId[$progId]
    if (-not $reg) { $exe = Get-ProgIdExe $progId; if ($exe) { $reg = $index.ByExe[$exe] } }
    $a = if ($reg) { $index.Apps[$reg] }
    if ($a) { return "ms-settings:defaultapps?registeredApp$(if ($a.Hive -eq 'HKLM') { 'Machine' } else { 'User' })=$([uri]::EscapeDataString($a.RegName))" }
    'ms-settings:defaultapps'
}

if ($Method -eq 'Direct') {
    # A Windows driver blocks scripts from writing these, whatever the hash (.htm and .html on newer builds)
    $locked = 'http', 'https', '.pdf', '.htm', '.html'
    $protected = @($todo | Where-Object { $_.Identifier -in $locked })
    $writable = @($todo | Where-Object { $_.Identifier -notin $locked })
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    function Set-UserChoice($id, $progId) {
        $path = "$(if ($id.StartsWith('.')) { $FileExts } else { $UrlAssoc })\$id\UserChoice".Substring(5)
        for ($try = 0; $try -lt 3; $try++) {
            $hkcu.DeleteSubKey($path, $false)   # Windows locks the existing key against edits, so replace it
            $k = $hkcu.CreateSubKey($path)
            try {
                $k.SetValue('ProgId', $progId)
                $k.SetValue('Hash', [Win32.UserChoice]::Hash($id, $sid, $progId, [DateTime]::UtcNow.ToFileTimeUtc()))
                # The hash covers the minute the key was written; redo it in the rare case the minute ticked over
                if ($k.GetValue('Hash') -eq [Win32.UserChoice]::Hash($id, $sid, $progId, [Win32.UserChoice]::LastWrite($k))) { return }
            } finally { $k.Close() }
        }
    }
    if ($writable.Count) {
        Write-Host "`nImport sets $($writable.Count) of these directly."
        if ($protected.Count) { Write-Host "Windows only lets you set $(($protected.Identifier | Sort-Object) -join ', ') in Settings, so Import walks you through $(if ($protected.Count -eq 1) { 'that' } else { 'those' }) after." }
        if (-not $Yes) {
            $a = Read-Host "`nSet them now? (Y/N)"
            if ($a -notmatch '^(y|yes)$') { Write-Host 'Cancelled. Nothing was changed.'; return }
        }
        $works = $null
        foreach ($t in $writable) {
            if ($works -eq $false) { break }
            try { Set-UserChoice $t.Identifier $t.ProgId } catch { Write-Warning "Couldn't write $($t.Identifier): $($_.Exception.Message)"; continue }
            if ($null -eq $works) {
                # Check the first one took before writing the rest
                [Win32.UserChoice]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)   # SHCNE_ASSOCCHANGED
                $works = [bool](Test-IsSet $t)
                if (-not $works) {
                    Write-Host "`nWindows ignored that, which means UserChoiceLatest is on for this PC (see ""How Windows protects default apps"" in the README)." -ForegroundColor Yellow
                    Write-Host 'Switching to setting them in Settings instead.'
                }
            }
        }
        [Win32.UserChoice]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        $notSet = @($writable | Where-Object { -not (Test-IsSet $_) })
        if ($works) { Write-Host "$($writable.Count - $notSet.Count) of $($writable.Count) set." -ForegroundColor $(if ($notSet.Count) { 'Yellow' } else { 'Green' }) }
        $todo = @($protected) + $notSet
    } else { $todo = $protected }
    if (-not $todo.Count) { Write-Host "`nDone." -ForegroundColor Green; return }
    $Method = 'Guided'
}

if ($Method -eq 'Guided') {
    # One app at a time: open its page in Settings, list the types, then check which ones took.
    # Apps that never registered with Windows have a separate ProgId-based key per type, so group those by name.
    $groups = @($todo | Group-Object { $k = Get-AppKey $_.ProgId $index; if ($k -like 'progid:*') { "name:$($_.AppName)" } else { $k } } | Sort-Object { $_.Group[0].AppName })
    Write-Host "`nImport opens each app's Default apps page in Settings, one at a time ($($groups.Count) app$(if ($groups.Count -ne 1) { 's' }))."
    Write-Host 'Windows only lets you set these there, so it lists what to click and checks each one off.'
    if (-not $Yes) {
        $a = Read-Host "`nStart? (Y/N)"
        if ($a -notmatch '^(y|yes)$') { Write-Host 'Cancelled. Nothing was changed.'; return }
    }
    $left = New-Object System.Collections.Generic.List[object]
    $i = 0; $stopped = $false
    foreach ($g in $groups) {
        $i++
        $pending = @($g.Group | Where-Object { -not (Test-IsSet $_) })   # one may have been set along with an earlier app
        if (-not $pending.Count) { continue }
        if ($stopped) { $left.AddRange([object[]]$pending); continue }
        $name = $g.Group[0].AppName
        Write-Host "`n[$i/$($groups.Count)] $name" -ForegroundColor Cyan
        $uri = Get-SettingsUri $g.Group[0].ProgId
        if ($uri -eq 'ms-settings:defaultapps') { Write-Host "  Settings opens on Default apps. Search for each type below and choose $name." }
        else { Write-Host "  Settings opens on $name's page. If it lands on the main Default apps page instead, search for $name." }
        if (@($pending.Identifier) -contains 'http' -or @($pending.Identifier) -contains 'https') {
            Write-Host '  Tip: the "Set default" button at the top of its page sets links and web files in one click.'
        }
        Start-Process $uri
        while ($true) {
            Write-Host "  Set to ${name} ($($pending.Count)): $(($pending | ForEach-Object Identifier | Sort-Object) -join ', ')"
            $a = Read-Host '  Press Enter when done (S skips this app, Q stops)'
            $pending = @($pending | Where-Object { -not (Test-IsSet $_) })
            if (-not $pending.Count) { Write-Host '  All set.' -ForegroundColor Green; break }
            if ($a -match '^[sq]') { break }
            Write-Host '  Not set yet:' -ForegroundColor Yellow
        }
        $left.AddRange([object[]]$pending)
        if ($a -match '^q') { $stopped = $true }
    }
    $set = $todo.Count - $left.Count
    Write-Host "`n$set of $($todo.Count) set." -ForegroundColor $(if ($left.Count) { 'Yellow' } else { 'Green' })
    if ($left.Count) {
        Write-Host 'Still to set (run Import again to pick up where you left off):'
        $left | Group-Object AppName | ForEach-Object { Write-Host "  $($_.Name): $(($_.Group | ForEach-Object Identifier | Sort-Object) -join ', ')" }
    }
    return
}

# Policy route (domain-joined PCs)
if (-not $IsAdmin) { throw 'The Policy import method needs admin. Use Run-Import.bat and click Yes.' }
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