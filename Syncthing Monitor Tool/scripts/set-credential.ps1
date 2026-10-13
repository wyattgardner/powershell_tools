# Stores the sending account's app password for this PC, encrypted.
#
# DPAPI machine scope: SYSTEM (which runs the checks) can decrypt it, and no other
# PC can, so the file is useless if copied. Its permissions are cut to SYSTEM and
# Administrators. Written to credential-<computer name>.bin, which is gitignored.

$scriptPath = $MyInvocation.MyCommand.Path
. (Join-Path $PSScriptRoot "_common.ps1")
if (-not (Test-Elevated)) {
    Write-Host "Not elevated. Opening an admin window for the prompt..."
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command', "& '$($scriptPath -replace "'", "''")'")
    exit
}
if (-not $SmtpUser) { Write-Host "Set `$SmtpUser in settings.ps1 first (the address that sends the alerts)." -ForegroundColor Red; return }

# Reads the password a key at a time, showing * for each character. Not Read-Host
# -AsSecureString: it takes Ctrl+V as one literal control character, so pasting fails
# over Chrome Remote Desktop and in the classic console. Returns $null on Esc.
function Read-AppPassword {
    $chars = New-Object System.Collections.Generic.List[char]
    Write-Host -NoNewline "App password: "
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Write-Host ''; return -join $chars }
        if ($k.Key -eq 'Escape') { Write-Host ''; return $null }
        if ($k.Key -eq 'Backspace') {
            if ($chars.Count) { $chars.RemoveAt($chars.Count - 1); Write-Host -NoNewline "`b `b" }
            continue
        }
        if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'V') {
            $clip = Get-Clipboard -Raw
            if ($clip) { foreach ($c in $clip.ToCharArray()) { if (-not [char]::IsControl($c)) { $chars.Add($c); Write-Host -NoNewline '*' } } }
            continue
        }
        if (-not [char]::IsControl($k.KeyChar)) { $chars.Add($k.KeyChar); Write-Host -NoNewline '*' }
    }
}

Write-Host "App password for $SmtpUser. Not the account password: Gmail makes these at"
Write-Host "https://myaccount.google.com/apppasswords (needs 2-Step Verification on)."
Write-Host "16 letters, spaces optional. Paste with Ctrl+V or right-click. Esc or Ctrl+C to stop."
while ($true) {
    $plain = Read-AppPassword
    if ($null -eq $plain) { Write-Host "Stopped. Nothing saved." -ForegroundColor Yellow; return }
    $plain = $plain -replace '\s', ''
    if ($plain -match '^[a-zA-Z]{16}$') { break }
    Write-Host "That's $($plain.Length) characters, not 16 letters. App passwords look like 'abcd efgh ijkl mnop'. Try again, or press Esc to stop." -ForegroundColor Red
}

Add-Type -AssemblyName System.Security
$bytes = [Text.Encoding]::UTF8.GetBytes($plain); $plain = $null
$enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
[Array]::Clear($bytes, 0, $bytes.Length)
[IO.File]::WriteAllBytes($credFile, $enc)

$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($id in 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
}
Set-Acl $credFile $acl
Write-Host "Saved to $credFile (SYSTEM and Administrators only)." -ForegroundColor Green
Write-Host "Run check.cmd -TestEmail to try it. You can close this window."
