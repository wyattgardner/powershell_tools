# Minecraft RCON console for use from another PC on the LAN.
# Copy this whole lan-console folder to the other PC (install.cmd puts mcrcon.exe
# in it), make lan-console.config.ps1, then run lan-console.cmd.
#
# Settings (server address, port, password, optional log path) live in
# lan-console.config.ps1. Make it from lan-console.config.example.ps1.

$mcrcon = Join-Path $PSScriptRoot "mcrcon.exe"
$cfg    = Join-Path $PSScriptRoot "lan-console.config.ps1"
if (-not (Test-Path $cfg)) {
    Write-Host "No lan-console.config.ps1 next to this script." -ForegroundColor Red
    Write-Host "Copy lan-console.config.example.ps1 to lan-console.config.ps1 and fill it in."
    Read-Host "Press Enter to close"
    exit 1
}
$logPath = ""
. $cfg

$Host.UI.RawUI.WindowTitle = "Minecraft Console (LAN)"

if (-not (Test-Path $mcrcon)) {
    Write-Host "mcrcon.exe not found next to this script." -ForegroundColor Red
    Write-Host "Copy it from bin\ in the tools folder on the server PC."
    Read-Host "Press Enter to close"
    exit 1
}

Write-Host "Connecting to $serverHost`:$rconPort ..."
$probe = Test-NetConnection -ComputerName $serverHost -Port $rconPort -WarningAction SilentlyContinue
if (-not $probe.TcpTestSucceeded) {
    Write-Host "Cannot reach $serverHost on port $rconPort." -ForegroundColor Red
    Write-Host "Check: the server is running, you're on the same LAN, and the firewall"
    Write-Host "rule on the server PC still allows LAN (it blocks 'Internet' addresses only)."
    Read-Host "Press Enter to close"
    exit 1
}

$consoleLock = New-Object object

if ($logPath -and (Test-Path $logPath)) {
    $tailPs = [powershell]::Create()
    $tailPs.AddScript({
        param($path, $lockObj)
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fs)
        $reader.BaseStream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -ne $line) {
                [System.Threading.Monitor]::Enter($lockObj)
                try { [Console]::WriteLine($line) } finally { [System.Threading.Monitor]::Exit($lockObj) }
            } else {
                Start-Sleep -Milliseconds 500
            }
        }
    }).AddArgument($logPath).AddArgument($consoleLock) | Out-Null
    $tailPs.BeginInvoke() | Out-Null
    Write-Host "Following the server log."
} elseif ($logPath) {
    Write-Host "Log path set but not reachable, continuing without the live log." -ForegroundColor Yellow
}

Write-Host "Connected. Type a command and press Enter. 'exit' closes this window (server keeps running)."

try {
    while ($true) {
        $cmdLine = Read-Host ">"
        if ($cmdLine -ieq "exit") { break }
        if ($cmdLine.Trim() -ne "") {
            $response = & $mcrcon -H $serverHost -P $rconPort -p $rconPass $cmdLine 2>&1 | Out-String
            [System.Threading.Monitor]::Enter($consoleLock)
            try { [Console]::Write($response) } finally { [System.Threading.Monitor]::Exit($consoleLock) }
        }
    }
} finally {
    if ($tailPs) { $tailPs.Stop(); $tailPs.Dispose() }
}
