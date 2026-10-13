# PowerShell tools

Miscellaneous vibe-coded PowerShell tools for Windows. Each one lives in its own folder with its own README and launchers.

They run on the Windows PowerShell 5.1 that ships with Windows 11. Nothing to install.

## Tools

### [Windows Settings Tool](Windows%20Settings%20Tool/)

Brings a fresh Windows 11 install up to speed with your settings. Export on the old PC, import on the new one.

- Checks nearly every page of Settings: appearance, taskbar, Start, File Explorer, input, accessibility, privacy, power, time and region, plus machine-wide items like fast startup, UAC, and Windows Update options.
- Saves only what you've changed. It compares against Windows' own defaults and the Default user profile, and filters out caches and app-managed data.
- Writes `CHANGES.md` (what you changed and the default) and `CHANGES_LONG.md` (every saved value in full detail).
- `Run-Diff.bat` compares a backup with the current PC without changing anything.

### [Windows Default Apps Tool](Windows%20Default%20Apps%20Tool/)

Carries your default apps (which app opens each file type and link) to a fresh install.

- Saves only the choices that differ from Windows' defaults, grouped by app in `CHANGES.md`.
- On import, applies a choice only if that app is installed, and lists what it skipped.
- An app that replaced a Windows default also takes over the other types it supports. For example, Chrome over Edge covers every type Edge would otherwise open.
- Uses Windows' supported default associations policy, since scripts can't write default apps directly. The policy removes itself after it applies.

### [Minecraft Server Tool](Minecraft%20Server%20Tool/)

Runs one or more Spigot servers on a Windows PC as proper Windows services, using NSSM.

- Servers start at boot before anyone logs in, restart themselves if they crash, and save the world when Windows shuts down.
- `update.cmd`, or `/update` in-game, updates Spigot and plugins with one restart, and rolls everything back if the server doesn't come up right. Plugins from Modrinth are found by file hash, so there's no list to keep.
- Optional daily maintenance: updates, warnings to players, a restart, and optionally Windows updates and a reboot.
- A console window with the live log for typing commands, plus a version you can run from another PC on your network.

### [Syncthing Monitor Tool](Syncthing%20Monitor%20Tool/)

Emails you when Syncthing stops syncing, so a broken sync can't go unnoticed for months.

- Checks hourly as SYSTEM: the Syncthing service, when each device last connected, and folders stuck out of sync, errored, or left paused, plus disk and file system errors and disk health.
- New problems are emailed at once, with a daily reminder while they last and a "recovered" email when they clear.
- A weekly "all good" email, so if the emails stop, you know the monitor itself is broken.
- Sends through a Gmail app password, stored encrypted so only this PC's SYSTEM account can use it.

## Using them

Each tool's README covers setup and use. The Windows tools run from their `Run-*.bat` files, with default options in `config.example.psd1` and your own in `config.psd1`. The Minecraft tool starts from `install.cmd`, with options in `settings.ps1` and `install.config.ps1`. The Syncthing monitor starts from `set-credential.cmd` and `install.cmd`, with your email addresses in `settings.ps1`.

What the tools generate or what holds your own data (settings backups, reports, server folders and worlds, RCON passwords, the stored app password, downloaded binaries, logs) is excluded by each tool's `.gitignore`. The root `.gitignore` covers what applies everywhere, like logs and editor files.

## Disclaimer

These change Windows settings and the registry. Read each tool's README, use the preview and diff modes first, and use them at your own risk.

## License

[MIT](LICENSE)
