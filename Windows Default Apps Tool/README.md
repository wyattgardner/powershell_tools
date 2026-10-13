# Windows default apps transfer

Carries your default apps (which app opens each file type and link) to a fresh Windows 11 install. It only applies a choice when that app is actually installed on the new PC.

## Files

| File | What it does |
|---|---|
| `Run-Export.bat` | Double-click on the old PC to save your default apps |
| `Run-Preview.bat` | Read-only. Shows what import would set on this PC, and what it would skip |
| `Run-Import.bat` | Double-click on the new PC to apply them. Sets them directly where Windows allows, and walks you through Settings for the rest |
| `WindowsDefaultApps.ps1` | The script that does the work |
| `DefaultAppsBackup\` | Created by export |
| `DefaultAppsBackup\CHANGES.md` | Created by export. Every default app you've changed from Windows' defaults, grouped by app |
| `config.example.psd1` | Default options, with an explanation of each (see below) |
| `config.psd1` | Your own options, if you create it. Not tracked by git |
| `Logs\` | Transcripts of each run, when `Logging` is on |

## How it decides what to set

**Only your changes are saved.** Windows ships a list of its own defaults (`OEMDefaultAssociations.xml`). Anything still matching that list is left out.

**Only installed apps are applied.** On the new PC, each choice is checked against what's installed. If VLC isn't there, your VLC choices are skipped and listed so you know. Install it and run import again to pick them up.

**Apps take over everything they replaced.** If you chose Chrome over Edge for links, Chrome also gets every other type it supports that Edge would otherwise open: `.mhtml`, `.svg`, `.webp`, PDFs, and so on. Same for VLC over Media Player, classic Outlook over new Outlook, etc. Run `Run-Preview.bat` to see exactly which types that adds. If you only want your exact choices copied, use `-OnlyMine` (see below).

## Step 1: export on the old PC

Double-click `Run-Export.bat`. No admin needed. Open `DefaultAppsBackup\CHANGES.md` to see what was saved.

## Step 2: move it

Copy this whole folder to the new PC.

## Step 3: install your apps

Install Chrome, VLC, VS Code, Office, and whatever else you use. Apps that aren't installed yet get skipped.

## Step 4: preview, then import

1. Double-click `Run-Preview.bat` and check the list. Nothing changes.
2. Double-click `Run-Import.bat`, review the list again, and type **Y**. No admin needed.

Import first tries to set everything directly. That works on PCs without UserChoiceLatest, or where you've turned it off (see [How Windows protects default apps](#how-windows-protects-default-apps)). It sets the first type, checks Windows took it, then does the rest. http, https, `.pdf`, `.htm`, and `.html` are always left for Settings, since Windows blocks scripts from those.

Anything it can't set directly, it walks you through in Settings:

1. For each app, Import opens that app's page in Settings > Apps > Default apps and prints the types to set there. Click each type in Settings and pick the app.
2. Back in the Import window, press **Enter**. Import asks Windows which types took, ticks those off, and lists any that didn't so you can finish them. **S** skips the app, **Q** stops.

If Import says "Windows ignored that", UserChoiceLatest is on and everything goes through Settings. A few things make that quicker:

- **Browsers:** the **Set default** button at the top of the browser's page sets http, https, `.htm`, `.html`, and the other web types in one click.
- **Apps that never registered with Windows** (VS Code, 7-Zip, qBittorrent, and similar) don't have their own page, so Settings opens on the main Default apps page. Type each extension into the search box at the top and pick the app.
- **Big lists:** VLC has about 50 types. They're all on its page, so it's one long scroll rather than 50 searches.
- **Stopping partway is fine.** Run Import again later and it only lists what's still left.

## Domain-joined PCs: the Policy method

On a domain-joined PC, Import uses the Policy method instead (see `ImportMethod` under [Options](#options)). It asks for admin, applies everything in one go, and you **sign out and back in** to finish.

The import writes your choices to `C:\ProgramData\WindowsDefaultApps\associations.xml`, turns on the Windows policy "default associations configuration file", and sets up a one-time task that turns the policy back off 2 minutes after you sign in. Your defaults stick, and you can still change them normally afterwards. Without that cleanup, Windows would reset them at every sign-in.

**This only works on domain-joined PCs.** On a PC that isn't joined to a domain (most home and personal PCs, including every Windows 11 Home PC), Windows applies that policy only to brand-new user accounts, so your existing account won't change. See below.

## How Windows protects default apps

Windows guards default app choices so apps can't hijack them. There are 3 layers, and they decide what any tool can do:

| Protection | What it does | Applies to |
|---|---|---|
| **UserChoice hash** | Each choice is stored in a `UserChoice` registry key with a hash of the type, your user ID, the app, and a timestamp. A choice with a wrong hash is reset. The algorithm is publicly known, and Import's Direct method uses it. | All editions |
| **UserChoiceLatest** | A newer replacement for the above. Choices move to `UserChoiceLatest` keys, and the hash adds a machine ID. Windows ignores the old `UserChoice` keys once it's on. The algorithm isn't public. | Windows 11 Home and Pro, rolled out gradually through feature flags |
| **User Choice Protection Driver** (`UCPD.sys`) | A kernel driver that refuses registry writes from scripts and command-line tools (PowerShell, `reg.exe`, and others) for http, https, and `.pdf`, whatever the hash. Newer builds add `.htm` and `.html`. Admin doesn't help. | Windows 10 and 11 since early 2024 |

To see whether a PC has UserChoiceLatest, look under any type in `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts`, for example `.mp4`. A `UserChoiceLatest` subkey means it's on.

### Turning off UserChoiceLatest

UserChoiceLatest is controlled by 2 Windows feature flags:

| Flag | ID | What it does |
|---|---|---|
| AppDefaultHashRotation | `43229420` | Switches to the new hash format |
| AppDefaultHashRotationUpdateHashes | `27623730` | Migrates existing choices to the new format |

Turn both off with [ViVeTool](https://github.com/thebookisclosed/ViVe/releases), a free open-source tool for Windows feature flags. Do this yourself; it disables a Windows protection, so it's your call:

1. Download the latest `ViVeTool-v*-IntelAmd.zip` from the releases page (`ARM64CLR` for ARM PCs) and extract it, for example to `Downloads\ViVeTool`.
2. Right-click Start, choose **Terminal (Admin)**, and go to that folder. In PowerShell: `cd $env:USERPROFILE\Downloads\ViVeTool`. In Command Prompt: `cd /d %USERPROFILE%\Downloads\ViVeTool`.
3. Run:
   ```
   .\ViVeTool.exe /disable /id:43229420,27623730
   ```
   It should say it set the configuration successfully. In Command Prompt, leave off the `.\`.
4. Restart.
5. Run `Run-Import.bat`. If it sets types without opening Settings, it worked.

To undo it, run this and restart. The flags go back to whatever Microsoft's rollout says:

```
.\ViVeTool.exe /reset /id:43229420,27623730
```

Choices you already have keep working either way. Windows updates can turn the flags back on by themselves, so check again after a big update. Even with the flags off, http, https, `.pdf`, `.htm`, and `.html` stay protected by the driver and have to be set in Settings.

Background: [UserChoiceLatest: Microsoft's new protection for file type associations](https://kolbi.cz/blog/2025/04/20/userchoicelatest-microsofts-new-protection-for-file-type-associations/) (Christoph Kolbicz, who reverse-engineered it).

## Options

The defaults are in `config.example.psd1`. Don't edit that file, since updates replace it. To change an option, create `config.psd1` next to the script with only the options you want, for example:

```powershell
@{ Logging = $true }
```

Anything you leave out keeps its default. Command-line switches override both files.

| Option | Default | What it does |
|---|---|---|
| `ImportMethod` | `Auto` | How Import applies your choices. `Direct` writes them to the registry where Windows allows it and hands the rest to `Guided`. `Guided` walks you through Settings and works on any PC. `Policy` applies them at your next sign-in, but only on domain-joined PCs. `Auto` picks `Policy` on domain-joined PCs and `Direct` everywhere else |
| `RunAsAdmin` | `true` | Reopens Import in an admin window when it uses the Policy method. Guided, Export, and Preview never ask |
| `Logging` | `false` | Saves a transcript of every run to `Logs\` |
| `BackupPath` | `DefaultAppsBackup` | Where the backup goes. Relative paths are next to the script |
| `OnlyMine` | `false` | Apply only your exact choices, without apps taking over the types they replaced |
| `SkipConfirm` | `false` | Import without asking to start first |

## Running it manually

```
powershell -ExecutionPolicy Bypass -File .\WindowsDefaultApps.ps1 -Mode Export
powershell -ExecutionPolicy Bypass -File .\WindowsDefaultApps.ps1 -Mode Preview
powershell -ExecutionPolicy Bypass -File .\WindowsDefaultApps.ps1 -Mode Import
```

Add `-OnlyMine` to Preview or Import to apply only your exact choices, without the takeover. Add `-Yes` to Import to skip the confirmation.

## Troubleshooting

**Settings opens on the main Default apps page instead of the app's page**
That app didn't register with Windows under the name Import expected. Type the app's name into the search box under "Set defaults for applications", open it, and set the listed types there.

**Pressing Enter says a type isn't set, but I set it**
Import asks Windows which app opens the type right now. If Settings shows a different app, set it again, since the choice dialog sometimes closes without saving. If Settings shows the right app and Import still disagrees, press **S** to move on and note the type and app so the tool can be fixed.

**An app has no page, or the type isn't in its list**
The app doesn't tell Windows it supports that type. Right-click a file of that type in File Explorer, choose **Open with > Choose another app**, pick the app (use **Choose an app on your PC** if it isn't listed), and click **Always**.

**Policy method: a default didn't change after signing in**
On a PC that isn't domain-joined, this is expected: the policy only applies to new accounts. Set `ImportMethod` to `Guided`, or leave it on `Auto`. On a domain-joined PC, run `Run-Preview.bat`. If it still lists the type, sign out and in once more. If the policy is gone and it's still listed, check the app is registered with Windows (open it once, or look for it in Settings > Apps > Default apps).

**Policy method: defaults keep resetting at every sign-in**
The cleanup task didn't run. In an admin PowerShell:

```
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name DefaultAssociationsConfiguration
```
