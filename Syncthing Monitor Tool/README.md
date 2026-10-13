# Syncthing monitor

Emails you when [Syncthing](https://syncthing.net) stops syncing, so a broken sync can't go unnoticed for months.

Syncthing fails quietly. A crashed service, a device that stopped connecting, or a folder stuck out of sync all look fine until you need the copy on the other PC. This checks every hour, as SYSTEM, and emails you about anything wrong. It also watches the disks, since a failing disk under a synced folder can sync its damage to every other device.

- New problems are emailed at once, with a daily reminder while they last and a "recovered" email when they clear.
- A weekly "all good" email means silence never goes unnoticed: if those stop arriving, the monitor itself is broken.
- No spam: the same problem is never emailed twice in a row outside the daily reminder.

## Requirements

- Windows 10 or 11 (Windows PowerShell 5.1 is built in)
- Admin rights on the PC
- Syncthing running as a Windows service (the [Syncthing Windows Setup](https://github.com/Bill-Stewart/SyncthingWindowsSetup) installer does this). If it runs some other way, see `$SyncthingService` and `$SyncthingHome` below.
- A Gmail account to send from, with 2-Step Verification on. A separate account just for alerts is best.

## Files

| File | What it does |
|---|---|
| `install.cmd` | Registers the hourly check as a scheduled task (asks for admin). `install.cmd -Uninstall` removes it |
| `set-credential.cmd` | Stores the sending account's app password for this PC, encrypted |
| `check.cmd` | Runs one check now. `-DryRun` shows what it would email; `-TestEmail` sends a test |
| `settings.defaults.ps1` | Default settings, with an explanation of each |
| `ALERTS.md` | Every alert it can send, what each means, and how to turn one off |
| `settings.ps1` | Your settings: at least the two email addresses. Not tracked by git |
| `scripts\` | The PowerShell behind the `.cmd` files |
| `credential-<pc>.bin` | The encrypted app password. Not tracked by git |
| `state-<pc>.json` | What's currently wrong and when you were last emailed. Not tracked by git |
| `logs\monitor-<pc>.log` | One line per check, plus every email sent. Not tracked by git |

## Setup

1. **Settings.** Create `settings.ps1` next to `settings.defaults.ps1` with the two addresses:

   ```powershell
   $AlertTo  = "you@example.com"          # who gets the alerts
   $SmtpUser = "alerts.sender@gmail.com"  # the Gmail account that sends them
   ```

2. **App password.** Gmail doesn't accept an account's normal password from scripts. Signed in as the sending account:
   1. Turn on 2-Step Verification at [myaccount.google.com/security](https://myaccount.google.com/security). Having a recovery phone isn't the same thing; the 2-Step Verification row itself must say On.
   2. Go to [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords), name it (for example "Syncthing monitor"), and click Create.
   3. Copy the 16-letter code. Google shows it only once.

   If that page says the setting isn't available, 2-Step Verification isn't on yet, or you're signed in as a different account.

3. **Store it.** Run `set-credential.cmd`. An admin window asks for the code and saves it. Spaces are optional, each character shows as `*`, and Ctrl+V pasting works, including over remote desktop. A wrong entry asks again; Esc or Ctrl+C stops without saving. Paste only into that prompt, never into chat or a file.

4. **Test.** Run `check.cmd -TestEmail` from an admin prompt and check the inbox. If it lands in spam, mark it "Not spam" so real alerts don't.

5. **Install.** Run `install.cmd`. It checks the settings and credential are in place, registers the task, and runs a first check.

## What it checks

Each check has its own alert ID. [ALERTS.md](ALERTS.md) explains every alert, including a common false positive from hard drive spin-up, and how to stop one being emailed with `$IgnoreAlerts`.

| Check | A problem when |
|---|---|
| Syncthing service | It isn't running. The email includes the crash reason from Syncthing's log and how often it crashed in the last day |
| Syncthing's API | The service is running but doesn't answer |
| Each remote device | It hasn't connected for `$DeviceUnseenHours` (24) |
| Each folder | It's in an error state (at once); files can't sync, this PC needs files, or a connected device is behind, for `$OutOfSyncHours` (24) |
| Paused folders and devices | Still paused after `$OutOfSyncHours`, since a forgotten pause syncs nothing |
| Busy folders | Syncthing hasn't answered for that folder for `$OutOfSyncHours`. A big folder can take over a minute to answer while it syncs; that alone isn't a problem |
| Disk and file system errors | Any error or warning from the disk, NTFS, or storage drivers, or a WHEA hardware error, in the last 24 hours |
| Disk health | Windows reports a physical disk as anything but Healthy |

The 24-hour waits are there because a big sync can legitimately take hours. A device that's simply off for a night won't trigger anything; one that's gone for a day will.

## When it emails

- **New problem:** at the first check that finds it. One email covers everything found in that check.
- **Still broken:** one reminder a day, at the first check at or after `$ReminderHour` (16:00). Skipped if the last email was under 12 hours ago, so a problem found at 3 PM doesn't get a reminder at 4.
- **Recovered:** when a problem clears.
- **Weekly check-in:** every week, at the first check at or after `$HeartbeatDay` `$HeartbeatHour` (Saturday 16:00), **no matter what**: whether or not other emails went out that week, and whether or not something is broken. That's what makes silence meaningful: if a check-in doesn't arrive, the monitor itself has stopped. The subject says `all good`, `all recovered`, or how many problems are still open, and the body lists them. If a brand-new problem turns up at check-in time, its own subject comes first, with `+ weekly check-in` after it.
- **Ignored this week:** every check-in lists the alerts `$IgnoreAlerts` suppressed since the last one: each alert ID, how many times, and first and last seen. Disk events are counted once each; conditions like a paused folder are counted per hourly check. See [ALERTS.md](ALERTS.md).

Every email ends with the current status of the service, each device and folder, and the disks. Subjects start with the PC's name in lowercase, like `[myserver] Syncthing: Laptop not seen for 3 days`.

If an email fails to send, nothing is marked as sent, so the next check tries again.

## Settings

Defaults are in `settings.defaults.ps1`; override any of them in `settings.ps1`.

| Setting | Default | What it does |
|---|---|---|
| `$AlertTo` | (required) | Who gets the alerts |
| `$SmtpUser` | (required) | The Gmail account that sends them |
| `$SmtpServer` / `$SmtpPort` | `smtp.gmail.com` / `587` | Any SMTP server with STARTTLS should work |
| `$DeviceUnseenHours` | `24` | How long a device can go without connecting |
| `$OutOfSyncHours` | `24` | How long a folder can stay behind, paused, or unreadable |
| `$CheckDiskErrors` | `$true` | Disk and file system error alerts, and disk health |
| `$DiskEventProviders` | disk, NTFS, storage drivers, WHEA | Event log sources counted as disk errors |
| `$IgnoreAlerts` | none | Alert IDs never emailed, wildcards allowed. See [ALERTS.md](ALERTS.md). Ignored alerts still show in the status section and the log |
| `$ReminderHour` | `16` | Hour (24h) for daily reminders |
| `$HeartbeatDay` / `$HeartbeatHour` | `Saturday` / `16` | Weekly check-in. `$HeartbeatDay = ""` turns it off |
| `$SyncthingService` / `$SyncthingHome` | auto | The service running `syncthing.exe`, and its `--home` folder |

### Settings for one PC

`settings.ps1` is PowerShell, and `$machine` holds the PC's name in lowercase (the same name as in email subjects and file names). Wrap a setting in an `if` to apply it on one PC only. Anything outside an `if` applies to every PC:

```powershell
$AlertTo  = "you@example.com"
$SmtpUser = "alerts.sender@gmail.com"

if ($machine -eq 'my-desktop') {
    # This PC's hard drive logs harmless retries when it spins up. See ALERTS.md.
    $IgnoreAlerts = @('disk-event:disk:153', 'disk-event:storahci:129')
}
if ($machine -eq 'my-server') {
    $DeviceUnseenHours = 48
}
```

That way one `settings.ps1` serves every PC when the tool folder is synced between them (see [More than one PC](#more-than-one-pc)). A per-PC line overrides the same setting set earlier in the file, so put shared settings first and the `if` blocks after. To check which values a PC ends up with, run `check.cmd -DryRun` on it.

## How the app password is stored

`set-credential.cmd` encrypts it with Windows DPAPI in machine scope, then cuts the file's permissions to SYSTEM and Administrators. SYSTEM (which runs the checks) can decrypt it; other accounts on the PC can't read the file, and on any other PC it can't be decrypted at all.

An app password can only send mail as that account. It can't sign in to it or change its settings. To revoke it, delete it at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords). Changing the account's password revokes it too, so then create a new one and run `set-credential.cmd` again.

Syncthing's own API key is read from its `config.xml` at every check and never logged or saved.

## More than one PC

Install it on every PC in the sync, each with its own `set-credential.cmd` (the stored password only works on the PC that stored it). Then if one PC dies outright and can't email, the other notices it's gone.

The credential, state, and log files carry the PC's name, so the tool folder can itself sit inside a synced folder without two PCs overwriting each other. In that case, add this to that folder's `.stignore` (adjusting the path), since Syncthing's account can't read the credential and would report it as an error on every scan:

```
/path/to/Syncthing Monitor Tool/credential-*.bin
```

## Things that will bite you

**Moving the folder.** The task points at this folder. After moving it, run `install.cmd` again.

**A huge folder answers slowly.** During a big sync, Syncthing can take over a minute to report on a folder with a million-plus files. The monitor waits 90 seconds, then lists the folder as busy and checks the rest. It only alerts if that lasts `$OutOfSyncHours`.

**Running a check by hand.** `check.cmd` needs admin to read Syncthing's config and the credential. From a normal prompt, the check can't read them and reports that as a problem.

## Layout

```
Syncthing Monitor Tool\
   install.cmd                  register the hourly check (start here, after setup)
   set-credential.cmd           store the app password
   check.cmd                    one check now (-DryRun, -TestEmail)
   settings.defaults.ps1        default settings
   ALERTS.md                    every alert, and how to ignore one
   settings.ps1                 your settings (gitignored)
   credential-<pc>.bin          encrypted app password (gitignored)
   state-<pc>.json              current problems, last emails (gitignored)
   logs\monitor-<pc>.log        one line per check (gitignored)
   scripts\                     the PowerShell behind the .cmd files
```
