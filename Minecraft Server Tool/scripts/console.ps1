param([string]$Server)   # server folder; default from settings ($DefaultServer)

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "_shared.ps1")

$Host.UI.RawUI.WindowTitle = $ServerName

$consoleLock = New-Object object

# Background thread: print the current session's log, then follow new lines live.
$tailPs = [powershell]::Create()
$tailPs.AddScript({
    param($path, $lockObj, $scanBytes)
    # FileShare must include Delete so the file can be renamed or removed while we
    # hold it. Without it, anything rotating this log is blocked.
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    # The log may not exist yet (the service recreates it on start). Wait for it
    # rather than throwing: this runs in a runspace that swallows errors, so
    # failing here would silently leave the console with no log at all.
    $fs = $null
    while ($null -eq $fs) {
        try {
            $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    $openedAt = [System.IO.File]::GetCreationTimeUtc($path)
    # Replay the current session only. The log keeps every past session, so
    # replaying the file means dumping tens of thousands of old lines.
    if ($fs.Length -gt $scanBytes) {
        $fs.Seek(-$scanBytes, [System.IO.SeekOrigin]::End) | Out-Null
    }
    $reader = New-Object System.IO.StreamReader($fs)
    if ($fs.Position -gt 0) { $reader.ReadLine() | Out-Null }  # drop the partial first line

    $recent = New-Object System.Collections.Generic.List[string]
    while ($null -ne ($l = $reader.ReadLine())) { $recent.Add($l) }

    # Start at the most recent server startup; fall back to the last 200 lines.
    $start = -1
    for ($i = $recent.Count - 1; $i -ge 0; $i--) {
        if ($recent[$i] -match 'Starting minecraft server version') { $start = $i; break }
    }
    if ($start -lt 0) { $start = [Math]::Max(0, $recent.Count - 200) }

    [System.Threading.Monitor]::Enter($lockObj)
    try { for ($i = $start; $i -lt $recent.Count; $i++) { [Console]::WriteLine($recent[$i]) } }
    finally { [System.Threading.Monitor]::Exit($lockObj) }

    while ($true) {
        $line = $reader.ReadLine()
        if ($null -ne $line) {
            [System.Threading.Monitor]::Enter($lockObj)
            try { [Console]::WriteLine($line) } finally { [System.Threading.Monitor]::Exit($lockObj) }
        } else {
            Start-Sleep -Milliseconds 300
            # If the log was rotated or replaced, follow the new file.
            try {
                if ([System.IO.File]::GetCreationTimeUtc($path) -ne $openedAt) {
                    $reader.Dispose(); $fs.Dispose()
                    Start-Sleep -Milliseconds 500
                    $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
                    $reader = New-Object System.IO.StreamReader($fs)
                    $openedAt = [System.IO.File]::GetCreationTimeUtc($path)
                }
            } catch { }
        }
    }
}).AddArgument($ServerLog).AddArgument($consoleLock).AddArgument(256KB) | Out-Null
$tailPs.BeginInvoke() | Out-Null

Start-Sleep -Milliseconds 400   # let the session replay land before the prompt appears

# One line only. mcrcon prints its own "Logged in." and Q-to-disconnect banner
# right after this, so repeating either here is just noise.
[Console]::WriteLine("--- $ServerName ---")

try {
    $announcedDown = $false
    while ($true) {
        # Terminal mode holds ONE rcon connection for the whole session. Invoking
        # mcrcon per command instead reconnects every time and spams the server log.
        $started = Get-Date
        & $mcrcon -H $RconHost -P $RconPort -p $RconPass -t
        $ranSeconds = ((Get-Date) - $started).TotalSeconds

        # Did the user quit, or did the connection fail? Decided from the JVM, not
        # from elapsed time: quitting with Q within a few seconds is indistinguishable
        # from "couldn't connect", and treating it as a failure made the console
        # reconnect in a loop instead of closing.
        # Deliberately no TCP liveness probe: a probe that succeeds shows up in the
        # server log as a connect AND disconnect right before the real connection.
        if ($ranSeconds -ge 3) { break }

        $jvm = Get-Jvm
        if ($jvm) {
            # JVM up and past its boot window, so rcon was available: the user quit.
            # Still booting means rcon isn't listening yet, so keep retrying.
            $age = 999
            try {
                $created = (Get-CimInstance Win32_Process -Filter "ProcessId=$jvm" -ErrorAction Stop).CreationDate
                if ($created) { $age = ((Get-Date) - $created).TotalSeconds }
            } catch { }
            if ($age -gt 60) { break }
        }

        if (-not $announcedDown) {
            [Console]::WriteLine(">>> Server not reachable. Retrying until it's back... (Ctrl-C to close)")
            $announcedDown = $true
        }
        Start-Sleep -Seconds 3
    }
} finally {
    $tailPs.Stop()
    $tailPs.Dispose()
}
