param(
    [switch]$DryRun,      # check and print what would be emailed; send nothing, save nothing
    [switch]$TestEmail    # just send a test email
)

# One check: Syncthing service, devices, folders, disks. Emails new problems at once,
# a reminder once a day while they last, and a "recovered" email when they clear.
# Run hourly as SYSTEM by the "Syncthing Monitor" scheduled task (install.cmd).
#
# Every check is wrapped on its own: if one fails (Syncthing's API is down, say),
# that failure is itself reported and the other checks still run.

. (Join-Path $PSScriptRoot "_common.ps1")
$now = Get-Date

if ($TestEmail) {
    Send-Alert "Test alert" "Test from the Syncthing monitor on $machine at $($now.ToString('yyyy-MM-dd HH:mm:ss')).`r`n`r`nIf you got this, alerts reach you."
    Write-Log "test email sent to $AlertTo"
    exit 0
}

# --- state ---------------------------------------------------------------------------
# Issues: what's currently wrong and when it was last emailed.
# Pending: when each out-of-sync condition was first seen (alerted after $OutOfSyncHours).
function ConvertTo-Hash($o) { $h = @{}; if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value } }; return $h }
$state = @{ Issues = @{}; Pending = @{}; LastHeartbeat = $null }
if (Test-Path $stateFile) {
    try {
        $j = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.Issues = ConvertTo-Hash $j.Issues
        foreach ($k in @($state.Issues.Keys)) { $state.Issues[$k] = ConvertTo-Hash $state.Issues[$k] }
        $state.Pending = ConvertTo-Hash $j.Pending
        $state.LastHeartbeat = $j.LastHeartbeat
    } catch { Write-Log "state file unreadable, starting fresh: $($_.Exception.Message)" }
}
$pendingNow = @{}       # out-of-sync conditions seen this run; anything not seen again is dropped

$issues  = [ordered]@{}     # key -> @{ Title; Detail }
$summary = New-Object Collections.Generic.List[string]
function Add-Issue([string]$Key, [string]$Title, [string]$Detail) { $script:issues[$Key] = @{ Title = $Title; Detail = $Detail } }
function Format-Age([timespan]$t) {
    if ($t.TotalDays -ge 2) { "{0:N0} days" -f $t.TotalDays } elseif ($t.TotalHours -ge 1) { "{0:N0} hours" -f $t.TotalHours } else { "{0:N0} minutes" -f $t.TotalMinutes }
}
# An out-of-sync condition only becomes an issue once it has lasted $OutOfSyncHours.
function Test-Lasting([string]$Key) {
    $since = if ($state.Pending[$Key]) { [datetime]$state.Pending[$Key] } else { $now }
    $script:pendingNow[$Key] = $since.ToString('o')
    return @{ Since = $since; Long = (($now - $since).TotalHours -ge $OutOfSyncHours) }
}

# --- 1. Syncthing service ------------------------------------------------------------------
$svc = $null; $stHome = $SyncthingHome; $api = $null
try {
    $svc = if ($SyncthingService) { Get-CimInstance Win32_Service -Filter "Name='$SyncthingService'" }
           else { Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'syncthing\.exe' } | Select-Object -First 1 }
    if (-not $svc) { throw "No Windows service running syncthing.exe was found. Set `$SyncthingService in settings.ps1." }
    if (-not $stHome -and $svc.PathName -match '-{1,2}home[= ]"?([^"]+?)"?(\s+-|\s*$)') { $stHome = $matches[1].Trim() }
    if (-not $stHome) { $stHome = Join-Path $env:LOCALAPPDATA "Syncthing" }

    if ($svc.State -ne 'Running') {
        $why = ""
        $log = Join-Path $stHome "syncthing.log"
        if (Test-Path $log) {
            $hit = Get-Content $log -Tail 300 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Syncthing stopped with error|FATAL|panic:' } | Select-Object -Last 1
            if ($hit) { $why = "`r`nLast error in syncthing.log:`r`n  $hit" }
        }
        $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7024, 7031, 7034; StartTime = $now.AddDays(-1) } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match [regex]::Escape($svc.DisplayName) }).Count
        Add-Issue 'service' "Syncthing service is $($svc.State.ToLower())" ("Service '{0}' is {1} (start type {2}). It crashed {3} time(s) in the last 24 hours.{4}" -f $svc.Name, $svc.State, $svc.StartMode, $crashes, $why)
        $summary.Add("Service: $($svc.State)")
    } else {
        $summary.Add("Service: running")
        # API key and address from config.xml (SYSTEM and Administrators can read it).
        [xml]$cfg = Get-Content (Join-Path $stHome "config.xml") -Raw -Encoding UTF8
        $gui = $cfg.configuration.gui
        $scheme = if ($gui.tls -eq 'true' -or (Test-Path (Join-Path $stHome "https-cert.pem"))) { 'https' } else { 'http' }
        $addr = ([string]$gui.address) -replace '^0\.0\.0\.0', '127.0.0.1' -replace '^\[::\]', '127.0.0.1'
        $api = @{ Base = "${scheme}://$addr"; Headers = @{ 'X-API-Key' = [string]$gui.apikey } }
    }
} catch { Add-Issue 'service-check' "Couldn't check the Syncthing service" $_.Exception.Message }

function Get-Api([string]$Path, [int]$Timeout = 20) { Invoke-RestMethod "$($api.Base)$Path" -Headers $api.Headers -TimeoutSec $Timeout -UseBasicParsing }
# Per-folder queries get longer: on a folder with a million-plus files, Syncthing can
# take well over 20 seconds to answer while it's busy syncing.
$folderTimeout = 90

# --- 2. devices and folders (only when Syncthing is up) ------------------------------------
if ($api) {
    try {
        # The API can lag the service by a few seconds after a start; one retry.
        try { $status = Get-Api "/rest/system/status" } catch { Start-Sleep -Seconds 15; $status = Get-Api "/rest/system/status" }
        $myId = $status.myID
        $devices = @(Get-Api "/rest/config/devices" | ForEach-Object { $_ }) | Where-Object { $_.deviceID -ne $myId }
        $names = @{}; foreach ($d in $devices) { $names[$d.deviceID] = $d.name }
        $conns = (Get-Api "/rest/system/connections").connections
        $stats = Get-Api "/rest/stats/device"

        foreach ($d in $devices) {
            $id = $d.deviceID
            $connected = $conns.$id -and $conns.$id.connected
            if ($d.paused) {
                $t = Test-Lasting "paused-dev-$id"
                $summary.Add("Device $($d.name): paused since $($t.Since.ToString('yyyy-MM-dd HH:mm'))")
                if ($t.Long) { Add-Issue "paused-dev-$id" "Device $($d.name) paused for $(Format-Age ($now - $t.Since))" "Device $($d.name) has been paused since $($t.Since.ToString('yyyy-MM-dd HH:mm')). Nothing syncs with it until it's resumed." }
                continue
            }
            if ($connected) { $summary.Add("Device $($d.name): connected"); continue }
            $seen = $null
            if ($stats.$id -and $stats.$id.lastSeen) { $seen = [datetime]$stats.$id.lastSeen }
            if (-not $seen -or $seen.Year -lt 2000) {
                $summary.Add("Device $($d.name): never seen")
                Add-Issue "device-$id" "$($d.name) has never connected" "Device $($d.name) ($($id.Substring(0,7))) has never connected to this PC."
                continue
            }
            $age = $now - $seen
            $summary.Add("Device $($d.name): last seen $($seen.ToString('yyyy-MM-dd HH:mm')) ($(Format-Age $age) ago)")
            if ($age.TotalHours -ge $DeviceUnseenHours) {
                Add-Issue "device-$id" "$($d.name) not seen for $(Format-Age $age)" ("Device {0} ({1}) last connected {2}. Nothing has synced with it since." -f $d.name, $id.Substring(0,7), $seen.ToString('yyyy-MM-dd HH:mm'))
            }
        }

        foreach ($f in @(Get-Api "/rest/config/folders" | ForEach-Object { $_ })) {
            $label = if ($f.label) { $f.label } else { $f.id }
            if ($f.paused) {
                # Pausing is fine for a while; forgetting to resume isn't.
                $t = Test-Lasting "paused-$($f.id)"
                $summary.Add("Folder $label`: paused since $($t.Since.ToString('yyyy-MM-dd HH:mm'))")
                if ($t.Long) { Add-Issue "paused-$($f.id)" "Folder '$label' paused for $(Format-Age ($now - $t.Since))" "Folder '$label' has been paused since $($t.Since.ToString('yyyy-MM-dd HH:mm')). Nothing in it syncs until it's resumed." }
                continue
            }
            $fid = [uri]::EscapeDataString($f.id)
            try {
            $st = Get-Api "/rest/db/status?folder=$fid" $folderTimeout
            $need = [int64]$st.needTotalItems
            $pullErr = if ($st.PSObject.Properties['pullErrors']) { [int]$st.pullErrors } else { 0 }
            $line = "Folder $label`: $($st.state)"
            if ($need) { $line += ", needs $need item(s)" }
            if ($pullErr) { $line += ", $pullErr error(s)" }

            if ($st.state -eq 'error' -or $pullErr -gt 0) {
                $errs = @((Get-Api "/rest/folder/errors?folder=$fid" $folderTimeout).errors) | Where-Object { $_ } | Select-Object -First 5 | ForEach-Object { "  $($_.path): $($_.error)" }
                $msg = if ($st.PSObject.Properties['error'] -and $st.error) { "Folder error: $($st.error)`r`n" } else { "" }
                $t = Test-Lasting "folder-err-$($f.id)"
                # A folder in the error state is reported at once; file errors only once they last.
                if ($st.state -eq 'error' -or $t.Long) {
                    Add-Issue "folder-err-$($f.id)" "Folder '$label' has errors" ("{0}{1} file(s) can't sync, since {2}.`r`n{3}" -f $msg, $pullErr, $t.Since.ToString('yyyy-MM-dd HH:mm'), ($errs -join "`r`n"))
                }
            } elseif ($need -gt 0) {
                $t = Test-Lasting "folder-need-$($f.id)"
                if ($t.Long) { Add-Issue "folder-need-$($f.id)" "Folder '$label' out of sync for $(Format-Age ($now - $t.Since))" "This PC still needs $need item(s) ($([math]::Round([int64]$st.needBytes / 1MB)) MB) in '$label', since $($t.Since.ToString('yyyy-MM-dd HH:mm'))." }
            }

            # How far each connected device is behind on this folder.
            foreach ($fd in @($f.devices)) {
                $did = $fd.deviceID
                if ($did -eq $myId -or -not ($conns.$did -and $conns.$did.connected)) { continue }
                $c = Get-Api "/rest/db/completion?folder=$fid&device=$did" $folderTimeout
                if ([double]$c.completion -lt 100) {
                    $line += ", $($names[$did]) at $([math]::Floor([double]$c.completion))%"
                    $t = Test-Lasting "remote-$($f.id)-$did"
                    if ($t.Long) { Add-Issue "remote-$($f.id)-$did" "$($names[$did]) behind on '$label'" ("{0} has been below 100% on '{1}' since {2} (now {3:N1}%, {4} item(s) to go)." -f $names[$did], $label, $t.Since.ToString('yyyy-MM-dd HH:mm'), [double]$c.completion, $c.needItems) }
                }
            }
            $summary.Add($line)
            } catch {
                # A busy folder isn't a problem by itself; one that stays unreadable is.
                # Keep its other timers running instead of letting them restart.
                foreach ($k in @($state.Pending.Keys)) { if ($k -like "*-$($f.id)*") { $pendingNow[$k] = $state.Pending[$k] } }
                $t = Test-Lasting "folder-api-$($f.id)"
                $summary.Add("Folder $label`: busy, didn't answer within $folderTimeout s")
                if ($t.Long) { Add-Issue "folder-api-$($f.id)" "Folder '$label' unreadable for $(Format-Age ($now - $t.Since))" "Syncthing hasn't answered status queries for '$label' since $($t.Since.ToString('yyyy-MM-dd HH:mm')): $($_.Exception.Message)" }
            }
        }
    } catch { Add-Issue 'api' "Couldn't read Syncthing's status" "The service is running but its API at $($api.Base) didn't answer: $($_.Exception.Message)" }
}

# --- 3. disks ---------------------------------------------------------------------------------
if ($CheckDiskErrors) {
    try {
        # Last 24 hours, so the issue clears itself after a clean day.
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = $now.AddDays(-1) } -ErrorAction SilentlyContinue |
            Where-Object { $DiskEventProviders -contains $_.ProviderName })
        if ($ev) {
            $groups = $ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | ForEach-Object {
                $first = ($_.Group | Select-Object -Last 1).TimeCreated; $last = ($_.Group | Select-Object -First 1).TimeCreated
                $msg = (($_.Group[0].Message -split "`r?`n")[0]).Trim()
                if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '...' }
                "  {0} event {1}, {2}x ({3:MM-dd HH:mm} to {4:MM-dd HH:mm}): {5}" -f $_.Group[0].ProviderName, $_.Group[0].Id, $_.Count, $first, $last, $msg
            }
            Add-Issue 'disk-events' "$($ev.Count) disk or file system error(s) in the last 24 hours" ("From the Windows System event log:`r`n{0}`r`n`r`nCheck the disk before trusting it as a sync target. A failing disk syncs its damage to every other device." -f ($groups -join "`r`n"))
        }
        $summary.Add("Disk events (24h): $($ev.Count)")
        foreach ($pd in Get-PhysicalDisk) {
            if ($pd.HealthStatus -ne 'Healthy') {
                Add-Issue "disk-health-$($pd.DeviceId)" "Disk '$($pd.FriendlyName)' is $($pd.HealthStatus)" ("Windows reports {0} ({1:N0} GB) as {2}, operational status {3}." -f $pd.FriendlyName, ($pd.Size / 1GB), $pd.HealthStatus, ($pd.OperationalStatus -join ', '))
            }
            $summary.Add("Disk $($pd.FriendlyName): $($pd.HealthStatus)")
        }
    } catch { Add-Issue 'disk-check' "Couldn't check the disks" $_.Exception.Message }
}

# --- 4. decide what to email --------------------------------------------------------------------
$remindAt = $now.Date.AddHours($ReminderHour)
if ($now -lt $remindAt) { $remindAt = $remindAt.AddDays(-1) }      # the most recent reminder time
$new = @(); $still = @(); $fixed = @()
foreach ($k in $issues.Keys) {
    $old = $state.Issues[$k]
    if (-not $old -or -not $old.LastEmailed) { $new += $k; continue }
    $last = [datetime]$old.LastEmailed
    # Due once per reminder time; skipped if the last email was under 12 hours ago,
    # so a problem found at 3 PM doesn't get a reminder at 4.
    if ($last -lt $remindAt -and ($now - $last).TotalHours -ge 12) { $still += $k }
}
foreach ($k in $state.Issues.Keys) { if (-not $issues.Contains($k) -and $state.Issues[$k].LastEmailed) { $fixed += $k } }

$heartbeatDue = $false
if ($HeartbeatDay -and -not $issues.Count) {
    $hb = $now.Date.AddHours($HeartbeatHour)
    while ($hb.DayOfWeek -ne $HeartbeatDay -or $hb -gt $now) { $hb = $hb.AddDays(-1) }   # most recent heartbeat time
    $heartbeatDue = (-not $state.LastHeartbeat -or [datetime]$state.LastHeartbeat -lt $hb)
}

$subject = $null
if ($new) {
    $subject = "Syncthing: " + $issues[$new[0]].Title + $(if ($new.Count -gt 1) { " (+$($new.Count - 1) more)" })
} elseif ($still) {
    $subject = "Still broken: " + $issues[$still[0]].Title + $(if ($still.Count -gt 1) { " (+$($still.Count - 1) more)" })
} elseif ($fixed) {
    $subject = "Recovered: " + $state.Issues[$fixed[0]].Title + $(if ($fixed.Count -gt 1) { " (+$($fixed.Count - 1) more)" })
} elseif ($heartbeatDue) {
    $subject = "Syncthing: all good (weekly check-in)"
}

$body = New-Object Text.StringBuilder
if ($new)   { [void]$body.AppendLine("NEW PROBLEMS"); foreach ($k in $new) { [void]$body.AppendLine("* $($issues[$k].Title)`r`n$($issues[$k].Detail)`r`n") } }
$ongoing = @($issues.Keys | Where-Object { $new -notcontains $_ })
if ($ongoing) {
    [void]$body.AppendLine("STILL BROKEN")
    foreach ($k in $ongoing) { [void]$body.AppendLine("* $($issues[$k].Title) (first reported $(([datetime]$state.Issues[$k].Since).ToString('yyyy-MM-dd HH:mm')))`r`n$($issues[$k].Detail)`r`n") }
}
if ($fixed) { [void]$body.AppendLine("RECOVERED"); foreach ($k in $fixed) { [void]$body.AppendLine("* $($state.Issues[$k].Title)") }; [void]$body.AppendLine("") }
if (-not $issues.Count -and $heartbeatDue) { [void]$body.AppendLine("Nothing wrong this week.`r`n") }
[void]$body.AppendLine("CURRENT STATUS ($($now.ToString('yyyy-MM-dd HH:mm')))")
foreach ($l in $summary) { [void]$body.AppendLine("  $l") }
[void]$body.AppendLine("`r`nReminders while a problem lasts: daily at ${ReminderHour}:00. Weekly check-in: $HeartbeatDay ${HeartbeatHour}:00.")

Write-Log ("check: {0} issue(s){1}" -f $issues.Count, $(if ($issues.Count) { ": " + (($issues.Keys | ForEach-Object { $issues[$_].Title }) -join '; ') } else { "" }))
if ($DryRun) {
    Write-Host "`n--- DRY RUN: nothing sent, state not saved ---"
    if ($subject) { Write-Host "Would email $AlertTo`nSubject: [$machine] $subject`n`n$($body.ToString())" } else { Write-Host "Nothing to email.`n`n$($body.ToString())" }
    exit 0
}

$sent = $false
if ($subject) {
    try { Send-Alert $subject $body.ToString(); $sent = $true; Write-Log "emailed $AlertTo`: $subject" }
    catch { Write-Log "EMAIL FAILED (will retry next check): $($_.Exception.Message)" }
}

# --- 5. save state ------------------------------------------------------------------------------
# A failed email leaves the issue un-emailed, so the next check tries again.
$newIssues = @{}
foreach ($k in $issues.Keys) {
    $old = $state.Issues[$k]
    $rec = @{ Title = $issues[$k].Title; Since = $(if ($old -and $old.Since) { $old.Since } else { $now.ToString('o') }); LastEmailed = $(if ($old) { $old.LastEmailed } else { $null }) }
    if ($sent -and ($new -contains $k -or $still -contains $k)) { $rec.LastEmailed = $now.ToString('o') }
    $newIssues[$k] = $rec
}
if (-not $sent) { foreach ($k in $fixed) { $newIssues[$k] = $state.Issues[$k] } }    # keep until the "recovered" email goes out
# Any email proves the monitor is alive, so it counts as the week's check-in.
$hbOut = if ($sent) { $now.ToString('o') } else { $state.LastHeartbeat }
[pscustomobject]@{ Issues = $newIssues; Pending = $pendingNow; LastHeartbeat = $hbOut } | ConvertTo-Json -Depth 5 | Set-Content $stateFile -Encoding UTF8
exit 0
