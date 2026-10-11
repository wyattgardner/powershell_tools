param([string]$Server)   # server folder; default from settings ($DefaultServer)

# Starts the server and waits until it's actually up. Run elevated (prompts if not).
#
# Readiness is detected by finding a "Done (...)" line in the log with a timestamp
# from THIS run. Deliberately not by sending an rcon command: every rcon check
# appears in the server log as a connect + disconnect pair, which is noise on every
# single start. This relies on the ISO timestamps configured via log4j2.xml.

$scriptPath = $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $scriptPath) "_shared.ps1")

$timeoutSeconds = 180

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$ServerName] $msg"
    $line | Out-File -FilePath $StartLog -Append -Encoding utf8
    Write-Host $line
}

if (-not (Test-Elevated)) { Invoke-SelfElevate $scriptPath $Server; exit }

$Host.UI.RawUI.WindowTitle = "start $ServerName"

# Returns the "Done (" line stamped at or after $since, or $null.
function Get-BootLineSince([datetime]$since) {
    if (-not (Test-Path $ServerLog)) { return $null }
    try { $lines = Get-Content $ServerLog -Tail 80 -ErrorAction Stop } catch { return $null }
    foreach ($l in $lines) {
        if ($l -match '^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\].*\]: Done \(') {
            try {
                $t = [datetime]::ParseExact($matches[1], "yyyy-MM-dd'T'HH:mm:ss", $null)
                if ($t -ge $since) { return $l }
            } catch { }
        }
    }
    return $null
}

Write-Log "=== Start script started ==="

$svcObj = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svcObj) {
    Write-Log "Service '$ServiceName' not found. Nothing to do."
    Write-Log "=== Start script finished ==="
    Close-Window 20
    exit 1
}

$existing = Get-Jvm
if ($existing) {
    Write-Log "Already running (JVM $existing). Nothing to do."
    Write-Log "=== Start script finished ==="
    Close-Window
    exit 0
}

# Rotate minecraft.log now, while nothing holds it open. NSSM's own rotation
# (AppRotate*) is deliberately never used; see README.
if ($ServerLogRotateMB -gt 0 -and (Test-Path $ServerLog) -and (Get-Item $ServerLog).Length -ge $ServerLogRotateMB * 1MB) {
    $logDirSrv = Split-Path $ServerLog
    $base = [IO.Path]::GetFileNameWithoutExtension($ServerLog)
    $sizeMB = [math]::Round((Get-Item $ServerLog).Length / 1MB)
    $dest = Join-Path $logDirSrv ("{0}-{1}.log" -f $base, (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
    try {
        Move-Item $ServerLog $dest -ErrorAction Stop
        Write-Log "Rotated $base.log ($sizeMB MB) to $(Split-Path -Leaf $dest)."
        Get-ChildItem $logDirSrv -Filter "$base-*.log" | Sort-Object Name -Descending |
            Select-Object -Skip $ServerLogKeep | ForEach-Object { Remove-Item $_.FullName -Force; Write-Log "Deleted old $($_.Name)." }
    } catch { Write-Log "Couldn't rotate $base.log: $($_.Exception.Message)" }
}

Write-Log "Service was $($svcObj.Status). Sending start."

# A couple of seconds of slack so a Done written moments before we looked still counts.
$since = (Get-Date).AddSeconds(-3)
$t0 = Get-Date
& $nssm start $ServiceName | Out-Null

$deadline = (Get-Date).AddSeconds($timeoutSeconds)
$lastNote = Get-Date
while ((Get-Date) -lt $deadline) {
    $bootLine = Get-BootLineSince $since
    if ($bootLine) {
        $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        Write-Log "Server reported: $($bootLine.Trim())"
        Write-Log "Up in $elapsed seconds. JVM PID $(Get-Jvm)."
        Write-Log "=== Start script finished ==="
        Close-Window
        exit 0
    }
    if (((Get-Date) - $lastNote).TotalSeconds -ge 10) {
        $jvm = Get-Jvm
        Write-Log ("  still starting... service={0} jvm={1}" -f (Get-Service $ServiceName).Status, $(if ($jvm) { $jvm } else { 'none' }))
        $lastNote = Get-Date
    }
    Start-Sleep -Seconds 2
}

Write-Log "ERROR: timed out after $timeoutSeconds seconds without seeing a startup complete."
Write-Log "Service is $((Get-Service $ServiceName).Status), JVM $(Get-Jvm)."
Write-Log "Check the log: Get-Content `"$ServerLog`" -Tail 40"
Write-Log "=== Start script finished ==="
Close-Window 20
exit 1
