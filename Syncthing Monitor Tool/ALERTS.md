# Alerts

Every alert the monitor can send, what it means, and what to do about it. All of them are on by default.

## Turning an alert off

Each alert has an ID. To stop one from being emailed, list its ID in `$IgnoreAlerts` in `settings.ps1`. Wildcards work:

```powershell
$IgnoreAlerts = @(
    'disk-event:disk:153'        # one disk event type, on every disk
    'folder-paused:Archive'      # one folder
    'device-unseen:*'            # every device
)
```

To ignore something on one PC only, check `$machine`, the PC's name in lowercase:

```powershell
if ($machine -eq 'my-pc') { $IgnoreAlerts = @('disk-event:disk:153', 'disk-event:storahci:129') }
```

Ignored alerts are never emailed on their own, but nothing goes completely silent:

- **Every email's status section** lists what's being ignored right now.
- **The weekly check-in** has an "Ignored this week" section: each ignored alert ID, how many times it happened, and when it was first and last seen. Disk events are counted once each; conditions like a paused folder are counted once per hourly check. A sudden jump, like spin-up retries going from a few a week to dozens a day, can be the first sign of a real problem.
- **The log** counts ignored alerts on every check.

To see what a change would do before it takes effect, run `check.cmd -DryRun` from an admin prompt.

The names in IDs are what Syncthing shows: device names, and folder labels (or the folder ID if it has no label). Disk names are what Windows shows in Device Manager.

## Syncthing

| ID | Emailed when | What to do |
|---|---|---|
| `service-stopped` | The Syncthing service isn't running. The email includes the last error from Syncthing's log and how often it crashed in the last day. | Start it from Services, or restart the PC. If it keeps stopping, the crash reason in the email is the place to start. |
| `service-check` | The monitor couldn't find or inspect the Syncthing service at all. | Usually a setup problem: set `$SyncthingService` and `$SyncthingHome` if Syncthing doesn't run as a normal service. |
| `api-unreachable` | The service is running, but Syncthing's API didn't answer. | Often brief, like right after a restart or during a database migration. If it lasts, open the web GUI and restart the service. |

## Devices

| ID | Emailed when | What to do |
|---|---|---|
| `device-unseen:<device>` | A device hasn't connected for `$DeviceUnseenHours` (24). | Check that the other PC is on, Syncthing is running there, and both are online. |
| `device-never-connected:<device>` | A device is configured but has never connected. | Check its device ID and that the other side accepted this PC. |
| `device-paused:<device>` | A device has been paused for `$OutOfSyncHours` (24). | Resume it, or ignore it if you pause it on purpose. |
| `device-behind:<device>:<folder>` | A connected device has been below 100% on a folder for `$OutOfSyncHours`. | Look at that device: it's usually out of disk space, has file errors, or is still scanning. |

## Folders

| ID | Emailed when | What to do |
|---|---|---|
| `folder-error:<folder>` | The folder is in an error state (emailed at once), or some files have failed to sync for `$OutOfSyncHours`. The email lists up to 5 failed files and why. | The usual causes are a missing folder or `.stfolder` marker, a full disk, files open in another program, or paths that are too long. |
| `folder-behind:<folder>` | This PC has still needed files in the folder for `$OutOfSyncHours`. | Check that the devices that have those files are connected. |
| `folder-paused:<folder>` | The folder has been paused for `$OutOfSyncHours`. | Resume it, or ignore it if you keep it paused on purpose. |
| `folder-busy:<folder>` | Syncthing hasn't answered for this folder for `$OutOfSyncHours`. A folder with a million-plus files can take over a minute to answer while it syncs, which alone isn't a problem. | If it lasts a day, restart Syncthing and check the folder in the web GUI. |

## Disks

| ID | Emailed when | What to do |
|---|---|---|
| `disk-event:<provider>:<event id>` | The Windows System log has errors or warnings from the disk, NTFS, or storage drivers, or a WHEA hardware error, in the last 24 hours. All of them are grouped into one email, listed by type. | Depends on the event. See below. To turn all of them off at once, use `disk-events`. |
| `disk-health:<disk>` | Windows reports a physical disk as anything but Healthy. | Back up that disk now and plan to replace it. This is the clearest sign of a failing drive. |
| `disk-check` | The monitor couldn't read the event log or the disk list. | Usually a permissions problem. The scheduled task runs as SYSTEM, which normally can. |

### Possible false positive: hard drive spin-up

Two disk events also happen on a perfectly healthy hard drive:

- **`disk-event:disk:153`**: "The IO operation ... was retried."
- **`disk-event:storahci:129`** (or `stornvme:129`): "Reset to device ... was issued."

Windows turns off an idle hard drive after 20 minutes by default (Power Options > Hard disk > Turn off hard disk after). When something needs the drive again, it can take a few seconds to spin up, the storage controller gives up waiting, resets the link, and retries. The retry succeeds and nothing is lost, but both events are logged. They tend to come and go through the day, often during heavy use after quiet periods.

The same events can also mean a bad cable or a failing drive, so check before ignoring them:

1. **Look at the drive's SMART data**, for example with CrystalDiskInfo. Reallocated, pending, and uncorrectable sector counts should all be 0.
2. **Check the UltraDMA CRC error count.** If it climbs over time, the SATA cable or port is the problem. Replace the cable.
3. **If both are clean**, it's spin-up. Either ignore the 2 event types (ideally only on that PC, as above), or keep the drive spinning by setting "Turn off hard disk after" to Never for plugged-in power.

The `disk-health` alert still covers you: if the drive itself starts failing, Windows' health status changes and that alert isn't affected by ignoring these 2 events.
