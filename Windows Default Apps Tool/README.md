# Windows default apps transfer

Carries your default apps (which app opens each file type and link) to a fresh Windows 11 install. It only applies a choice when that app is actually installed on the new PC.

## Files

| File | What it does |
|---|---|
| `Run-Export.bat` | Double-click on the old PC to save your default apps |
| `Run-Preview.bat` | Read-only. Shows what import would set on this PC, and what it would skip |
| `Run-Import.bat` | Double-click on the new PC to apply them (asks for admin) |
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
2. Double-click `Run-Import.bat`, click **Yes** on the admin prompt, review the list again, and type **Y**.
3. **Sign out and back in.** That's when Windows applies them.

## Why sign out?

Windows signs default app choices with a per-PC hash and blocks scripts from writing them directly, especially for browsers and PDFs. The supported way around that is a Windows policy, "default associations configuration file", which applies an XML list of defaults when you sign in.

The import writes that XML to `C:\ProgramData\WindowsDefaultApps\associations.xml`, turns the policy on, and sets up a one-time task that turns the policy back off 2 minutes after you sign in. Your defaults stick, and you can still change them normally afterwards. Without that cleanup, Windows would reset them at every sign-in.

## Options

The defaults are in `config.example.psd1`. Don't edit that file, since updates replace it. To change an option, create `config.psd1` next to the script with only the options you want, for example:

```powershell
@{ Logging = $true }
```

Anything you leave out keeps its default. Command-line switches override both files.

| Option | Default | What it does |
|---|---|---|
| `RunAsAdmin` | `true` | Reopens Import in an admin window. Export and Preview never ask |
| `Logging` | `false` | Saves a transcript of every run to `Logs\` |
| `BackupPath` | `DefaultAppsBackup` | Where the backup goes. Relative paths are next to the script |
| `OnlyMine` | `false` | Apply only your exact choices, without apps taking over the types they replaced |
| `SkipConfirm` | `false` | Import without the Y/N prompt |
## Running it manually

```
powershell -ExecutionPolicy Bypass -File .\WindowsDefaultApps.ps1 -Mode Export
powershell -ExecutionPolicy Bypass -File .\WindowsDefaultApps.ps1 -Mode Preview
powershell -ExecutionPolicy Bypass -File .\WindowsDefaultApps.ps1 -Mode Import
```

Add `-OnlyMine` to Preview or Import to apply only your exact choices, without the takeover. Add `-Yes` to Import to skip the confirmation.

## Troubleshooting

**A default didn't change after signing in**
Run `Run-Preview.bat`. If it still lists the type, sign out and in once more. If the policy is gone and it's still listed, check the app is registered with Windows (open it once, or look for it in Settings > Apps > Default apps).

**Defaults keep resetting at every sign-in**
The cleanup task didn't run. In an admin PowerShell:

```
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name DefaultAssociationsConfiguration
```
