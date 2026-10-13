# Windows settings transfer

Brings a fresh Windows 11 install up to speed with your settings. It checks everything you can set in Windows itself, and the backup holds only what you've changed from the defaults.

Settings that apps manage themselves (Office's account info, Tailscale's hosts entries, and so on) are left out on purpose. The apps restore those when you install them.

## Files

| File | What it does |
|---|---|
| `Run-Export.bat` | Double-click on the old PC to save your changes (asks for admin) |
| `Run-Import.bat` | Double-click on the new PC to apply settings (asks for admin) |
| `Run-Diff.bat` | Read-only. Compares the backup with this PC's current settings |
| `WindowsSettings.ps1` | The script that does the work |
| `WinSettingsBackup\` | Created by export. Holds your saved settings |
| `WinSettingsBackup\CHANGES.md` | Created by export. Every setting you've changed from the Windows default, and what the default is |
| `WinSettingsBackup\CHANGES_LONG.md` | Created by export. Every item the backup holds in full detail: registry keys, values, what the Default profile had, why each one was saved, power GUIDs, and the full recorded lists |
| `DIFF.md` | Created by Run-Diff. What's different between the backup and this PC |
| `config.example.psd1` | Default options, with an explanation of each (see below) |
| `config.psd1` | Your own options, if you create it. Not tracked by git |
| `Logs\` | Transcripts of each run, when `Logging` is on |

## What gets copied

**Appearance:** wallpaper (the image itself) and fit, dark/light mode, transparency, animation effects, accent color, theme, cursors, lock screen (Spotlight or your own picture), screen saver, Night light, per-monitor scaling.

**Taskbar:** alignment, auto-hide, Widgets/Task View/Copilot/search buttons, combine buttons, badges, clock seconds, End task, pinned apps, tray icon visibility.

**Start:** layout, pinned apps, recently added/most used apps, recommendations, account notifications.

**File Explorer and desktop:** hidden files, file extensions, opens to, full path, classic right-click menu, Quick access pins, recent/frequent files in Home, navigation pane, compact view, check boxes, folder views (icon size, sort, columns), desktop icons, Documents/Downloads/etc. locations.

**System:** notifications (global and per app), tips and suggestions, clipboard history, Storage Sense, snap layouts, shake to minimize, nearby sharing, per-app GPU preference, system sounds, communications ducking, user environment variables.

**Devices:** AutoPlay on/off and what happens when you plug in a removable drive, memory card, or phone (like "Open folder to view files").

**Mouse, keyboard, and touch:** pointer speed and acceleration, double-click, scrolling, key repeat, Num Lock at sign-in, Print Screen key, input language hotkeys, touchpad gestures, touch keyboard, text suggestions and autocorrect.

**Accessibility:** Sticky/Filter/Toggle/Mouse Keys and their shortcuts, text size, scrollbars, mono audio, text cursor, Magnifier, Narrator, color filters, captions.

**Gaming:** Game Mode, Game Bar, captures.

**Privacy and search:** advertising ID, tailored experiences, language list, app launch tracking, inking and typing, online speech, app permissions (camera, mic, location, etc.), SafeSearch, search history, search highlights, cloud search.

**Time and region:** time zone, languages and keyboards, date/time/number formats, first day of week, home location.

**Power:** every power plan setting you've changed (sleep, screen off, power button, lid, etc.). Windows' own CPU tuning is left alone so it fits the new PC's hardware.

**Machine-wide (needs admin on import):** fast startup, hibernate on/off, UAC level, diagnostic data, AutoPlay policy, Remote Desktop, Remote Assistance, Developer Mode, sudo, startup sound, set time/time zone automatically, Windows Update options and active hours, device privacy switches (location services, etc.), system locale, hosts file entries you added.

**Recorded, not applied by default:** Windows service startup types, disabled scheduled tasks, optional features (Hyper-V, WSL, .NET 3.5, etc.), and other machine policies. Windows keeps no defaults for these, so the tool can't tell your changes from stock values. `CHANGES.md` lists them, Run-Diff compares them, and import applies them only if you ask (see "Running it manually").

## How "only changes" works

- **Named settings** (the ones in `CHANGES.md` tables): the tool knows the Windows default for each one.
- **Everything else under your user account** (folder views, per-app notifications, touchpad, Night light, and so on): compared with the Default user profile, the template Windows copies for every new account. That's why export asks for admin.
- **Power:** only values you overrode. Windows' own CPU tuning is left alone so it fits the new PC.
- **Pins, Quick access, time zone, languages:** these have no default, so they're always saved.

## What doesn't get copied

- Installed apps and their settings
- **Default apps** (which browser opens links, etc.). Use the Windows Default Apps Tool next to this folder.
- Wi-Fi networks and passwords
- Accounts, PIN, Windows Hello, sign-in options
- Printers and Bluetooth devices
- Display resolution, refresh rate, and HDR (they depend on the monitor)
- Installed fonts and language packs (languages are added, but Windows may download the pack)
- BitLocker, activation, drivers
- The PC's name, unless you turn on `ComputerName` (see [Options](#options))

## Step 1: export on the old PC

1. Double-click `Run-Export.bat` and click **Yes** on the admin prompt. Export only reads your settings. Admin is needed to read the Default user profile for comparison.
2. A window lists what was saved. Press any key to close it.
3. Open `WinSettingsBackup\CHANGES.md` to see what you've changed from the Windows defaults.

Each export replaces the previous backup, so it always reflects the PC as it is right now. If you click **No**, export still works, but it can't compare, so it saves every value instead of only your changes.

## Step 2: move it

Copy the whole folder to the new PC: the 3 .bat files, `WindowsSettings.ps1`, and `WinSettingsBackup\`. A USB drive or OneDrive works fine.

## Step 3: import on the new PC

**Install your apps first.** Taskbar and Start pins for apps that aren't installed yet won't show up.

1. Double-click `Run-Import.bat`.
2. Click **Yes** on the admin prompt. Without admin, the machine-wide settings are skipped.
3. The taskbar disappears for a few seconds while Explorer restarts. That's normal.
4. Press any key to close the window when it says Done.
5. Restart the PC so everything takes effect.

## Step 4 (optional): check it

Double-click `Run-Diff.bat` on the new PC. It doesn't change anything. It compares the backup with the new PC and writes `DIFF.md`:

- **Named settings** that differ, with a **Default** column: Yes means the new PC is still at the Windows default (so the import probably didn't take), No means it's set to something else, and n/a means there's no fixed default.
- **Other saved values** that differ, covering everything else the backup holds.
- **Recorded items** (services, tasks, features, policies) that differ.

Run-Diff also works on the old PC, to see what's changed since the last export.

## Options

The defaults are in `config.example.psd1`. Don't edit that file, since updates replace it. To change an option, create `config.psd1` next to the script with only the options you want, for example:

```powershell
@{ Logging = $true }
```

Anything you leave out keeps its default. Command-line switches override both files.

| Option | Default | What it does |
|---|---|---|
| `RunAsAdmin` | `true` | Reopens Export and Import in an admin window. Diff never asks |
| `Logging` | `false` | Saves a transcript of every run to `Logs\` |
| `BackupPath` | `WinSettingsBackup` | Where the backup goes. Relative paths are next to the script |
| `IncludeRecorded` | `false` | Import also applies service startup types, disabled scheduled tasks, optional features, and other machine policies |
| `ComputerName` | `''` | The PC's name on import. `''` leaves it alone, `'FromBackup'` uses the old PC's name, and anything else is the name to set (1-15 letters, digits, or hyphens, not only digits). Needs admin and takes effect after the restart. Run-Diff says what import would do |

## Running it manually

Open PowerShell in this folder:

```
powershell -ExecutionPolicy Bypass -File .\WindowsSettings.ps1 -Mode Export
powershell -ExecutionPolicy Bypass -File .\WindowsSettings.ps1 -Mode Import
powershell -ExecutionPolicy Bypass -File .\WindowsSettings.ps1 -Mode Diff
```

To also apply the recorded items (services, scheduled tasks, optional features, other machine policies), run import from an admin PowerShell with `-IncludeRecorded`:

```
powershell -ExecutionPolicy Bypass -File .\WindowsSettings.ps1 -Mode Import -IncludeRecorded
```

Check `DIFF.md` first so you know what that will change.

Add `-Path E:\SomeFolder` to use a different backup folder, `-ComputerName FromBackup` (or `-ComputerName NEW-NAME`) to rename the PC on import, or `-Log` to log just that run.

## Notes

- **Different username on the new PC:** handled. Paths like `C:\Users\OldName\...` are rewritten.
- **Wallpaper and lock screen:** the images are copied into `Pictures\Wallpapers` on the new PC.
- **Folder locations:** if you moved Documents to `D:\Documents`, it's only applied when that folder exists on the new PC.
- **Environment variables:** your user `Path` is merged, not replaced, so the new PC's entries stay.
- **Hibernate:** whether it's available, and its timers, are copied as is.
- **Re-running import:** safe. It just applies the same settings again.

## Troubleshooting

**"running scripts is disabled on this system"**
Use the .bat files or the full command with `-ExecutionPolicy Bypass`. Double-clicking the .ps1 directly won't work.

**"No backup found"**
The `WinSettingsBackup` folder isn't next to the script, or it was made by an older version of the tool. Re-run the export.

**Something didn't change**
Restart, then run `Run-Diff.bat`. Rows where Default says "Yes" are the ones that didn't apply.

**Taskbar doesn't come back after import**
Press Ctrl+Shift+Esc, then File > Run new task, type `explorer`, and press Enter.
