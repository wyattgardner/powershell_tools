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
# Ignored: alerts matched by $IgnoreAlerts since the last weekly digest, for the check-in.
# IgnoredSeen: newest ignored event counted per disk-event ID, so each event counts once.
function ConvertTo-Hash($o) { $h = @{}; if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value } }; return $h }
$state = @{ Issues = @{}; Pending = @{}; LastHeartbeat = $null; Ignored = @{}; IgnoredSeen = @{}; LastDigest = $null }
if (Test-Path $stateFile) {
    try {
        $j = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.Issues = ConvertTo-Hash $j.Issues
        foreach ($k in @($state.Issues.Keys)) { $state.Issues[$k] = ConvertTo-Hash $state.Issues[$k] }
        $state.Pending = ConvertTo-Hash $j.Pending
        $state.LastHeartbeat = $j.LastHeartbeat
        $state.Ignored = ConvertTo-Hash $j.Ignored
        foreach ($k in @($state.Ignored.Keys)) { $state.Ignored[$k] = ConvertTo-Hash $state.Ignored[$k] }
        $state.IgnoredSeen = ConvertTo-Hash $j.IgnoredSeen
        $state.LastDigest = $j.LastDigest
    } catch { Write-Log "state file unreadable, starting fresh: $($_.Exception.Message)" }
}
$pendingNow = @{}       # out-of-sync conditions seen this run; anything not seen again is dropped

$issues  = [ordered]@{}     # key -> @{ Title; Detail }
$summary = New-Object Collections.Generic.List[string]
# Every alert has an ID (ALERTS.md lists them all). IDs matching $IgnoreAlerts are never
# emailed; they're still listed in each email's status section and in the log.
$ignored = New-Object Collections.Generic.List[string]
function Test-Ignored([string]$AlertId) { foreach ($p in @($IgnoreAlerts)) { if ($p -and $AlertId -like $p) { return $true } }; return $false }
# Tally for the weekly digest. Unit is 'event' (disk events, each counted once) or
# 'check' (a condition, counted once per hourly check it was seen in).
function Add-IgnoredTally([string]$Id, [string]$Unit, [datetime]$When) {
    $e = $state.Ignored[$Id]
    if (-not $e) { $e = @{ Count = 0; Unit = $Unit; First = $When.ToString('o'); Last = $When.ToString('o') }; $state.Ignored[$Id] = $e }
    $e.Count = [int]$e.Count + 1
    if ($When -gt [datetime]$e.Last) { $e.Last = $When.ToString('o') }
    if ($When -lt [datetime]$e.First) { $e.First = $When.ToString('o') }
}
function Add-Issue([string]$Key, [string]$AlertId, [string]$Title, [string]$Detail) {
    if (Test-Ignored $AlertId) { $script:ignored.Add("$AlertId ($Title)"); Add-IgnoredTally $AlertId 'check' $now; return }
    $script:issues[$Key] = @{ Title = $Title; Detail = $Detail; Alert = $AlertId }
}
# "1 problem", "2 problems". Never "problem(s)".
function Plural([int64]$n, [string]$one, [string]$many = "${one}s") { "$n " + $(if ($n -eq 1) { $one } else { $many }) }
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
        Add-Issue 'service' 'service-stopped' "Syncthing service is $($svc.State.ToLower())" ("Service '{0}' is {1} (start type {2}). It crashed {3} in the last 24 hours.{4}" -f $svc.Name, $svc.State, $svc.StartMode, (Plural $crashes 'time'), $why)
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
} catch { Add-Issue 'service-check' 'service-check' "Couldn't check the Syncthing service" $_.Exception.Message }

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
                if ($t.Long) { Add-Issue "paused-dev-$id" "device-paused:$($d.name)" "Device $($d.name) paused for $(Format-Age ($now - $t.Since))" "Device $($d.name) has been paused since $($t.Since.ToString('yyyy-MM-dd HH:mm')). Nothing syncs with it until it's resumed." }
                continue
            }
            if ($connected) { $summary.Add("Device $($d.name): connected"); continue }
            $seen = $null
            if ($stats.$id -and $stats.$id.lastSeen) { $seen = [datetime]$stats.$id.lastSeen }
            if (-not $seen -or $seen.Year -lt 2000) {
                $summary.Add("Device $($d.name): never seen")
                Add-Issue "device-$id" "device-never-connected:$($d.name)" "$($d.name) has never connected" "Device $($d.name) ($($id.Substring(0,7))) has never connected to this PC."
                continue
            }
            $age = $now - $seen
            $summary.Add("Device $($d.name): last seen $($seen.ToString('yyyy-MM-dd HH:mm')) ($(Format-Age $age) ago)")
            if ($age.TotalHours -ge $DeviceUnseenHours) {
                Add-Issue "device-$id" "device-unseen:$($d.name)" "$($d.name) not seen for $(Format-Age $age)" ("Device {0} ({1}) last connected {2}. Nothing has synced with it since." -f $d.name, $id.Substring(0,7), $seen.ToString('yyyy-MM-dd HH:mm'))
            }
        }

        foreach ($f in @(Get-Api "/rest/config/folders" | ForEach-Object { $_ })) {
            $label = if ($f.label) { $f.label } else { $f.id }
            if ($f.paused) {
                # Pausing is fine for a while; forgetting to resume isn't.
                $t = Test-Lasting "paused-$($f.id)"
                $summary.Add("Folder $label`: paused since $($t.Since.ToString('yyyy-MM-dd HH:mm'))")
                if ($t.Long) { Add-Issue "paused-$($f.id)" "folder-paused:$label" "Folder '$label' paused for $(Format-Age ($now - $t.Since))" "Folder '$label' has been paused since $($t.Since.ToString('yyyy-MM-dd HH:mm')). Nothing in it syncs until it's resumed." }
                continue
            }
            $fid = [uri]::EscapeDataString($f.id)
            try {
            $st = Get-Api "/rest/db/status?folder=$fid" $folderTimeout
            $need = [int64]$st.needTotalItems
            $pullErr = if ($st.PSObject.Properties['pullErrors']) { [int]$st.pullErrors } else { 0 }
            $line = "Folder $label`: $($st.state)"
            if ($need) { $line += ", needs $(Plural $need 'item')" }
            if ($pullErr) { $line += ", $(Plural $pullErr 'error')" }

            if ($st.state -eq 'error' -or $pullErr -gt 0) {
                $errs = @((Get-Api "/rest/folder/errors?folder=$fid" $folderTimeout).errors) | Where-Object { $_ } | Select-Object -First 5 | ForEach-Object { "  $($_.path): $($_.error)" }
                $msg = if ($st.PSObject.Properties['error'] -and $st.error) { "Folder error: $($st.error)`r`n" } else { "" }
                $t = Test-Lasting "folder-err-$($f.id)"
                # A folder in the error state is reported at once; file errors only once they last.
                if ($st.state -eq 'error' -or $t.Long) {
                    Add-Issue "folder-err-$($f.id)" "folder-error:$label" "Folder '$label' has errors" ("{0}{1} can't sync, since {2}.`r`n{3}" -f $msg, (Plural $pullErr 'file'), $t.Since.ToString('yyyy-MM-dd HH:mm'), ($errs -join "`r`n"))
                }
            } elseif ($need -gt 0) {
                $t = Test-Lasting "folder-need-$($f.id)"
                if ($t.Long) { Add-Issue "folder-need-$($f.id)" "folder-behind:$label" "Folder '$label' out of sync for $(Format-Age ($now - $t.Since))" "This PC still needs $(Plural $need 'item') ($([math]::Round([int64]$st.needBytes / 1MB)) MB) in '$label', since $($t.Since.ToString('yyyy-MM-dd HH:mm'))." }
            }

            # How far each connected device is behind on this folder.
            foreach ($fd in @($f.devices)) {
                $did = $fd.deviceID
                if ($did -eq $myId -or -not ($conns.$did -and $conns.$did.connected)) { continue }
                $c = Get-Api "/rest/db/completion?folder=$fid&device=$did" $folderTimeout
                if ([double]$c.completion -lt 100) {
                    $line += ", $($names[$did]) at $([math]::Floor([double]$c.completion))%"
                    $t = Test-Lasting "remote-$($f.id)-$did"
                    if ($t.Long) { Add-Issue "remote-$($f.id)-$did" "device-behind:$($names[$did]):$label" "$($names[$did]) behind on '$label'" ("{0} has been below 100% on '{1}' since {2} (now {3:N1}%, {4} to go)." -f $names[$did], $label, $t.Since.ToString('yyyy-MM-dd HH:mm'), [double]$c.completion, (Plural $c.needItems 'item')) }
                }
            }
            $summary.Add($line)
            } catch {
                # A busy folder isn't a problem by itself; one that stays unreadable is.
                # Keep its other timers running instead of letting them restart.
                foreach ($k in @($state.Pending.Keys)) { if ($k -like "*-$($f.id)*") { $pendingNow[$k] = $state.Pending[$k] } }
                $t = Test-Lasting "folder-api-$($f.id)"
                $summary.Add("Folder $label`: busy, didn't answer within $folderTimeout s")
                if ($t.Long) { Add-Issue "folder-api-$($f.id)" "folder-busy:$label" "Folder '$label' unreadable for $(Format-Age ($now - $t.Since))" "Syncthing hasn't answered status queries for '$label' since $($t.Since.ToString('yyyy-MM-dd HH:mm')): $($_.Exception.Message)" }
            }
        }
    } catch { Add-Issue 'api' 'api-unreachable' "Couldn't read Syncthing's status" "The service is running but its API at $($api.Base) didn't answer: $($_.Exception.Message)" }
}

# --- 3. disks ---------------------------------------------------------------------------------
if ($CheckDiskErrors) {
    try {
        # Last 24 hours, so the issue clears itself after a clean day.
        $all = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = $now.AddDays(-1) } -ErrorAction SilentlyContinue |
            Where-Object { $DiskEventProviders -contains $_.ProviderName })
        # Each event type is its own alert ID, disk-event:<provider>:<id>, so harmless ones can be ignored alone
        $allDiskIgnored = Test-Ignored 'disk-events'
        $ev = @($all | Where-Object { -not $allDiskIgnored -and -not (Test-Ignored "disk-event:$($_.ProviderName):$($_.Id)") })
        $ignEv = @($all | Where-Object { $ev -notcontains $_ })
        $skipped = $ignEv.Count
        if ($skipped) { $ignored.Add("$(Plural $skipped 'disk event') in the last 24 hours") }
        # The 24-hour window overlaps between hourly checks, so tally only events newer than the last one counted.
        foreach ($g in ($ignEv | Group-Object ProviderName, Id)) {
            $gid = "disk-event:$($g.Group[0].ProviderName):$($g.Group[0].Id)"
            $seen = if ($state.IgnoredSeen[$gid]) { [datetime]$state.IgnoredSeen[$gid] } else { [datetime]::MinValue }
            $fresh = @($g.Group | Where-Object { $_.TimeCreated -gt $seen } | Sort-Object TimeCreated)
            foreach ($x in $fresh) { Add-IgnoredTally $gid 'event' $x.TimeCreated }
            if ($fresh) { $state.IgnoredSeen[$gid] = $fresh[-1].TimeCreated.ToString('o') }
        }
        if ($ev) {
            $groups = $ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | ForEach-Object {
                $first = ($_.Group | Select-Object -Last 1).TimeCreated; $last = ($_.Group | Select-Object -First 1).TimeCreated
                $msg = (($_.Group[0].Message -split "`r?`n")[0]).Trim()
                if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '...' }
                "  {0} event {1}, {2}x ({3:MM-dd HH:mm} to {4:MM-dd HH:mm}): {5}" -f $_.Group[0].ProviderName, $_.Group[0].Id, $_.Count, $first, $last, $msg
            }
            # Retries (disk 153) and link resets (storahci/stornvme 129) are also what a hard drive
            # does when it's slow to spin back up after Windows parked it. Say so, so it's not mistaken for a dying disk.
            $spinUp = if ($ev | Where-Object { ($_.ProviderName -eq 'disk' -and $_.Id -eq 153) -or ($_.ProviderName -in 'storahci', 'stornvme' -and $_.Id -eq 129) }) {
                "`r`n`r`nPossible false positive: disk 153 (I/O retried) and storahci 129 (reset to device) also happen when a hard drive takes too long to spin back up after Windows turned it off for being idle. If the drive's SMART data is clean and these events come and go, that's the likely cause. See ALERTS.md (disk-event) for how to check and how to ignore them."
            } else { "" }
            Add-Issue 'disk-events' 'disk-events' "$(Plural $ev.Count 'disk or file system error') in the last 24 hours" ("From the Windows System event log:`r`n{0}`r`n`r`nCheck the disk before trusting it as a sync target. A failing disk syncs its damage to every other device.{1}" -f ($groups -join "`r`n"), $spinUp)
        }
        $summary.Add("Disk events (24h): $($ev.Count)$(if ($skipped) { " (+$skipped ignored)" })")
        foreach ($pd in Get-PhysicalDisk) {
            if ($pd.HealthStatus -ne 'Healthy') {
                Add-Issue "disk-health-$($pd.DeviceId)" "disk-health:$($pd.FriendlyName)" "Disk '$($pd.FriendlyName)' is $($pd.HealthStatus)" ("Windows reports {0} ({1:N0} GB) as {2}, operational status {3}." -f $pd.FriendlyName, ($pd.Size / 1GB), $pd.HealthStatus, ($pd.OperationalStatus -join ', '))
            }
            $summary.Add("Disk $($pd.FriendlyName): $($pd.HealthStatus)")
        }
    } catch { Add-Issue 'disk-check' 'disk-check' "Couldn't check the disks" $_.Exception.Message }
}

if ($ignored.Count) { $summary.Add("Ignored by `$IgnoreAlerts: " + ($ignored -join '; ')) }

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

# Weekly check-in: sent every week no matter what (other emails, open problems, or nothing
# to report), so if it ever stops arriving, the monitor itself is broken. Only the
# check-in resets the weekly timer. $HeartbeatDay = "" turns it off.
$heartbeatDue = $false
if ($HeartbeatDay) {
    $hb = $now.Date.AddHours($HeartbeatHour)
    while ($hb.DayOfWeek -ne $HeartbeatDay -or $hb -gt $now) { $hb = $hb.AddDays(-1) }   # most recent heartbeat time
    $heartbeatDue = (-not $state.LastHeartbeat -or [datetime]$state.LastHeartbeat -lt $hb)
}
# The week's ignored alerts go out with every check-in.
$digestDue = $heartbeatDue -and $state.Ignored.Count -gt 0

$subject = $null
if ($new) {
    # A brand-new problem leads the subject even when the check-in is due in the same email.
    $subject = "Syncthing: " + $issues[$new[0]].Title + $(if ($new.Count -gt 1) { " (+$($new.Count - 1) more)" }) + $(if ($heartbeatDue) { " + weekly check-in" })
} elseif ($heartbeatDue) {
    $subject = "Syncthing: weekly check-in, " + $(if ($issues.Count) { "$(Plural $issues.Count 'problem') still open" } elseif ($fixed) { "all recovered" } else { "all good" })
} elseif ($still) {
    $subject = "Still broken: " + $issues[$still[0]].Title + $(if ($still.Count -gt 1) { " (+$($still.Count - 1) more)" })
} elseif ($fixed) {
    $subject = "Recovered: " + $state.Issues[$fixed[0]].Title + $(if ($fixed.Count -gt 1) { " (+$($fixed.Count - 1) more)" })
}

$body = New-Object Text.StringBuilder
if ($new)   { [void]$body.AppendLine("NEW PROBLEMS"); foreach ($k in $new) { [void]$body.AppendLine("* $($issues[$k].Title)`r`n$($issues[$k].Detail)`r`n") } }
$ongoing = @($issues.Keys | Where-Object { $new -notcontains $_ })
if ($ongoing) {
    [void]$body.AppendLine("STILL BROKEN")
    foreach ($k in $ongoing) { [void]$body.AppendLine("* $($issues[$k].Title) (first reported $(([datetime]$state.Issues[$k].Since).ToString('yyyy-MM-dd HH:mm')))`r`n$($issues[$k].Detail)`r`n") }
}
if ($fixed) { [void]$body.AppendLine("RECOVERED"); foreach ($k in $fixed) { [void]$body.AppendLine("* $($state.Issues[$k].Title)") }; [void]$body.AppendLine("") }
if ($heartbeatDue) {
    [void]$body.AppendLine("WEEKLY CHECK-IN")
    [void]$body.AppendLine("The monitor is running on $machine. This email comes every week, whatever else is going on; if one doesn't arrive, check the 'Syncthing Monitor' scheduled task.")
    if (-not $issues.Count) { [void]$body.AppendLine($(if ($digestDue) { "Nothing wrong right now, apart from what you've chosen to ignore below." } else { "Nothing wrong right now." })) }
    [void]$body.AppendLine("")
}
$digestSent = $false
if ($digestDue -and $subject) {
    $since = if ($state.LastDigest) { ([datetime]$state.LastDigest).ToString('yyyy-MM-dd HH:mm') } else { 'the last check-in' }
    [void]$body.AppendLine("IGNORED THIS WEEK (`$IgnoreAlerts, since $since)")
    foreach ($k in ($state.Ignored.Keys | Sort-Object)) {
        $e = $state.Ignored[$k]
        $times = if ($e.Unit -eq 'event') { Plural $e.Count 'event' } else { Plural $e.Count 'hourly check' }
        [void]$body.AppendLine(("  {0}: {1}, {2:ddd MM-dd HH:mm} to {3:ddd MM-dd HH:mm}" -f $k, $times, [datetime]$e.First, [datetime]$e.Last))
    }
    [void]$body.AppendLine("  A sudden jump here can be the first sign of a real problem. See ALERTS.md.`r`n")
    $digestSent = $true
}
[void]$body.AppendLine("CURRENT STATUS ($($now.ToString('yyyy-MM-dd HH:mm')))")
foreach ($l in $summary) { [void]$body.AppendLine("  $l") }
[void]$body.AppendLine("`r`nReminders while a problem lasts: daily at ${ReminderHour}:00. Weekly check-in: $HeartbeatDay ${HeartbeatHour}:00.")

Write-Log ("check: {0}{1}{2}" -f (Plural $issues.Count 'issue'), $(if ($issues.Count) { ": " + (($issues.Keys | ForEach-Object { $issues[$_].Title }) -join '; ') } else { "" }), $(if ($ignored.Count) { " ($($ignored.Count) ignored)" } else { "" }))
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
    # A check-in lists every open problem, so it counts as their reminder too.
    if ($sent -and ($new -contains $k -or $still -contains $k -or $heartbeatDue)) { $rec.LastEmailed = $now.ToString('o') }
    $newIssues[$k] = $rec
}
if (-not $sent) { foreach ($k in $fixed) { $newIssues[$k] = $state.Issues[$k] } }    # keep until the "recovered" email goes out
# Only the check-in itself resets the weekly timer; other emails don't count.
$hbOut = if ($sent -and $heartbeatDue) { $now.ToString('o') } else { $state.LastHeartbeat }
# The week's ignored tally restarts once its digest has gone out.
$ignOut = if ($sent -and $digestSent) { @{} } else { $state.Ignored }
$digestOut = if ($sent -and $digestSent) { $now.ToString('o') } else { $state.LastDigest }
[pscustomobject]@{ Issues = $newIssues; Pending = $pendingNow; LastHeartbeat = $hbOut; Ignored = $ignOut; IgnoredSeen = $state.IgnoredSeen; LastDigest = $digestOut } | ConvertTo-Json -Depth 5 | Set-Content $stateFile -Encoding UTF8
exit 0
