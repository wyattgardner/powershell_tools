param([string]$Server)   # server folder; default from settings ($DefaultServer)

# Saves, stops the server, then stops the SERVICE so NSSM doesn't restart it.
# Registered as the Group Policy shutdown script, where it runs as SYSTEM.

$scriptPath = $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $scriptPath) "_shared.ps1")

$waitSeconds = 25

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$ServerName] $msg"
    $line | Out-File -FilePath $ShutdownLog -Append -Encoding utf8
    Write-Host $line
}

# Must be elevated BEFORE we touch anything. Without admin, Stop-Service fails and
# NSSM restarts the server seconds later, so we'd stop the server and fail to keep
# it down. Group Policy runs this as SYSTEM, which is already elevated, so it never
# takes this branch (important: nothing here may block, or it would stall shutdown).
if (-not (Test-Elevated)) { Invoke-SelfElevate $scriptPath $Server; exit }

if ([Environment]::UserInteractive) { $Host.UI.RawUI.WindowTitle = "stop $ServerName" }

$t0 = Get-Date
Write-Log "=== Shutdown script started ==="

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    Write-Log "Service '$ServiceName' not found. Nothing to do."
    Write-Log "=== Shutdown script finished ==="
    Close-Window
    exit 0
}
if ($svc.Status -ne 'Running') {
    Write-Log "Service is $($svc.Status), not Running. Nothing to do."
    Write-Log "=== Shutdown script finished ==="
    Close-Window
    exit 0
}

# Identify this server's JVM as the child of the service wrapper. Other Java
# servers run on this box, and the JVM runs as LocalSystem so its command line
# is not readable from every context.
$wrapperPid = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).ProcessId
$mcPid = $null
if ($wrapperPid) {
    $mcPid = (Get-CimInstance Win32_Process -Filter "Name='java.exe' AND ParentProcessId=$wrapperPid" -ErrorAction SilentlyContinue).ProcessId
}
if ($mcPid) {
    Write-Log "Server JVM is PID $mcPid (service wrapper PID $wrapperPid)."
} else {
    Write-Log "WARNING: could not identify the server JVM; will rely on the service stop."
}

# No sleep between these two: save-all's reply only arrives once the save is done,
# so waiting afterwards achieves nothing.
Write-Log "Sending save-all over RCON."
$t = Get-Date
$out = & $mcrcon -H $RconHost -P $RconPort -p $RconPass "save-all" 2>&1 | ForEach-Object { "$_" } | Out-String
Write-Log "save-all response after $([math]::Round(((Get-Date) - $t).TotalSeconds,1))s: $($out.Trim())"

# Usually a couple of seconds, but occasionally ~20s: the server sometimes doesn't
# accept a new rcon connection for a while right after a save (an 18s gap has been
# seen with nothing logged server-side at all). Cause not established. mcrcon
# blocks until it connects, so say it out loud rather than looking frozen. The
# timings logged here are what will show whether it's a pattern.
Write-Log "Sending stop over RCON (usually instant; can occasionally stall ~20s)..."
$t = Get-Date
$out = & $mcrcon -H $RconHost -P $RconPort -p $RconPass "stop" 2>&1 | ForEach-Object { "$_" } | Out-String
Write-Log "stop response after $([math]::Round(((Get-Date) - $t).TotalSeconds,1))s: $($out.Trim())"

# Wait for the JVM to finish exiting BEFORE stopping the service. If the service is
# stopped while the app is still shutting down, NSSM works through its stop-method
# timeouts (30s console + 30s window + 5s threads) and Stop-Service blocks for a
# minute. Once the app is gone, NSSM's stop returns immediately.
# The poll is tight because NSSM restarts 5s after the app exits, so the window
# between "JVM gone" and "service stopped" has to stay well under that.
if ($mcPid) {
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    $exited = $false
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $mcPid -ErrorAction SilentlyContinue)) { $exited = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if ($exited) {
        Write-Log "Server JVM (PID $mcPid) exited cleanly."
    } else {
        Write-Log "WARNING: PID $mcPid still running after $waitSeconds seconds; stopping service anyway."
    }
}

try {
    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
    Write-Log "Service stopped. Down in $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) seconds."
} catch {
    Write-Log "ERROR: could not stop service: $($_.Exception.Message)"
    Write-Log "The server may be restarted by NSSM. Stop the service manually."
    Write-Log "=== Shutdown script finished ==="
    Close-Window 20
    exit 1
}

Write-Log "=== Shutdown script finished ==="
Close-Window
