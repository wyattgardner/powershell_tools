# Paths, settings, logging and email. Dot-sourced by every script.
#
# Per-machine files carry the computer name, so the tool folder can sit inside a
# synced folder (or be copied between PCs) without two machines overwriting each
# other's credential, state or log.

$toolRoot = Split-Path -Parent $PSScriptRoot      # this file is in scripts\
$machine  = $env:COMPUTERNAME.ToLower()       # in file names and email subjects
$credFile  = Join-Path $toolRoot "credential-$machine.bin"
$stateFile = Join-Path $toolRoot "state-$machine.json"
$logDir    = Join-Path $toolRoot "logs"
$logFile   = Join-Path $logDir "monitor-$machine.log"

. (Join-Path $toolRoot "settings.defaults.ps1")
$userSettings = Join-Path $toolRoot "settings.ps1"
if (Test-Path $userSettings) { . $userSettings }

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    try {
        New-Item -ItemType Directory $logDir -Force | Out-Null
        # Keep it small: past 1 MB, the current log becomes .old (one generation).
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Move-Item $logFile "$logFile.old" -Force }
        Add-Content $logFile $line -Encoding UTF8
    } catch { }
}

# Syncthing's GUI uses a self-signed certificate. Accept it for localhost only;
# every other host (Gmail included) gets normal certificate checking.
if (-not ('StmCertPolicy' -as [type])) {
    Add-Type @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class StmCertPolicy {
    public static void Install() {
        ServicePointManager.ServerCertificateValidationCallback = Check;
    }
    static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        if (errors == SslPolicyErrors.None) return true;
        HttpWebRequest req = sender as HttpWebRequest;
        if (req == null) return false;
        string h = req.RequestUri.Host;
        return h == "127.0.0.1" || h == "localhost" || h == "[::1]";
    }
}
"@
}
[StmCertPolicy]::Install()
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# The app password, decrypted. DPAPI machine scope: any account on THIS PC can
# decrypt it (the file's permissions limit that to SYSTEM and Administrators), and
# no other PC can.
function Get-SmtpPassword {
    if (-not (Test-Path $credFile)) { throw "No stored app password for $machine. Run set-credential.cmd." }
    Add-Type -AssemblyName System.Security
    $enc = [IO.File]::ReadAllBytes($credFile)
    [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine))
}

function Send-Alert([string]$Subject, [string]$Body) {
    if (-not $AlertTo -or -not $SmtpUser) { throw "Set `$AlertTo and `$SmtpUser in settings.ps1." }
    $smtp = New-Object Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
    $smtp.EnableSsl = $true
    $smtp.Credentials = New-Object Net.NetworkCredential($SmtpUser, (Get-SmtpPassword))
    try { $smtp.Send($SmtpUser, $AlertTo, "[$machine] $Subject", $Body) }
    finally { $smtp.Dispose() }
}
