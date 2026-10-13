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

Write-Host "App password for $SmtpUser. Not the account password: Gmail makes these at"
Write-Host "https://myaccount.google.com/apppasswords (needs 2-Step Verification on)."
$sec = Read-Host "App password (16 letters, spaces OK)" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $plain = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) -replace '\s', '' }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ($plain -notmatch '^[a-zA-Z]{16}$') {
    Write-Host "That isn't 16 letters. App passwords look like 'abcd efgh ijkl mnop'. Nothing saved." -ForegroundColor Red
    return
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
