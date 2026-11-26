# Factorio Server Tool

Runs a Factorio dedicated server on a Windows PC as a Windows service, using
[NSSM](https://nssm.cc), the same way the Minecraft Server Tool runs Spigot.

- Starts at boot, before anyone logs in.
- Restarts itself 10 s after it crashes or exits for any reason.
- Saves the map whenever it's stopped: NSSM stops it with Ctrl+C, and Factorio saves on Ctrl+C.
- Copies the save to `server\backups` on every stop and nightly. That folder is inside the
  Syncthing-synced Projects folder, so backups land on the other PC too.
- `update.cmd` updates the game with steamcmd and keeps saves and settings.

No RCON. Nothing to install besides the game itself; `install.cmd` downloads NSSM (pinned
build, SHA-256 checked).

## Layout

| Where | What |
|---|---|
| `C:\Servers\Factorio Server` (`$GameDir`) | Game files from steamcmd, plus Factorio's write-data: `saves\`, `mods\`, `config\`, `factorio-current.log`, `logs\console.log` |
| `server\` in this folder | `server-settings.json` (name, game password), `server-adminlist.json`, `server-whitelist.json`, `backups\`. Gitignored, synced by Syncthing |
| `logs\` in this folder | This tool's logs: `factorio-tool.log`, `install.log`, `update.log` |
| `bin\nssm.exe` | Downloaded by `install.cmd`. The service runs this copy |

`config-path.cfg` in the game folder points Factorio's write-data at the game folder
instead of `%APPDATA%\Factorio`. That matters because the service runs as LocalSystem.

## First install

1. Install the game with steamcmd. Factorio isn't an anonymous download: the Steam account
   has to own it, and you type its password and Steam Guard code yourself:

   ```
   C:\Servers\steamcmd\steamcmd.exe +force_install_dir "C:\Servers\Factorio Server" +login <steam-account> +app_update 427520 validate +quit
   ```

2. Run `install.cmd` (asks for admin). It creates the service, the firewall rule, the
   nightly backup task, starts the server and waits until it's in game. On a first install
   it takes `server-settings.json`, the adminlist and whitelist from the game folder if
   they're there, else it starts from Factorio's example and you fill in the name and
   `game_password`.
3. Register the shutdown script (below).

Re-run `install.cmd` any time after changing `settings.ps1`. It never overwrites the files
in `server\`.

### The shutdown script

NSSM stops the service when Windows shuts down, but Windows only gives services a few
seconds. A Group Policy shutdown script runs first and isn't rushed, so register it:

1. `gpedit.msc` > Computer Configuration > Windows Settings > Scripts (Startup/Shutdown) >
   **Shutdown** > **PowerShell Scripts** tab > Add.
2. Script name: the full path to `shutdown-gp.ps1` in this folder. Leave **Parameters empty**.

## Everyday use

| Launcher | Does |
|---|---|
| `start.cmd` | Starts the service and waits until it's hosting |
| `stop.cmd` | Stops it (saves first), then copies a backup. It stays stopped until `start.cmd` or the next boot |
| `status.cmd` | Service state, version, whether the game is in game, players online, newest save and backup, firewall rule. No admin needed |
| `backup.cmd` | Copies the newest save to `server\backups` now. Safe while it runs |
| `update.cmd` | See below |
| `test.cmd` | Kills `factorio.exe` and checks NSSM restarts it, then checks `stop` saves and backs up and `start` hosts again. Players are disconnected for about a minute. Results in `logs\test.log` |

`start`, `stop`, `update`, `install` and `test` ask for admin on their own, since they control
a service. Every launcher writes a log in `logs\`.

Typing `/quit` in game as an admin or killing `factorio.exe` is a **restart**: NSSM brings it
back in 10 s. To keep it down, use `stop.cmd`.

Joining: the server PC's LAN IP on your network. From outside, your public IP on UDP 34197,
once the router forwards it to the server PC. Access is controlled by the whitelist
(`server\server-whitelist.json`, factorio.com usernames). A `game_password` in
`server-settings.json` is optional on top of it.

## Updating

Server and every client must be on exactly the same version, so update when everyone's
Steam has updated, or set the server back to match.

1. Run `update.cmd`. It stops the server (saves), backs up the save, runs steamcmd, puts
   `config-path.cfg` back (steamcmd's `validate` restores Steam's version, which would move
   saves to AppData), shows the old and new version, and starts the server.
2. steamcmd usually remembers the login. If it asks, type the password and Steam Guard code
   in that window.

Saves, mods, config and everything in `server\` are untouched by an update. The copy in
`server\backups` named `*-pre-update.zip` is the one to restore if the new version breaks
something.

To pin an older version, use a steamcmd beta branch: add `-beta <branch>` after
`app_update 427520` (branches are listed on the Betas tab of Factorio's Steam properties).

## Backups

- Every stop (`stop.cmd`, update, shutdown script, install) copies the newest save to
  `server\backups\<map>-<date>_<time>-<reason>.zip`.
- The `Factorio Nightly Backup` task does the same at 03:30, before the 04:00 Minecraft
  maintenance reboot.
- The newest 30 are kept (`$BackupKeep`).
- `server\` syncs to the other PC through Syncthing, so these are off-machine copies.
  Before an update, check that Syncthing shows Projects as up to date.

Factorio also keeps its own rolling autosaves in `saves\` (`_autosave1` to `_autosave10`,
every 10 minutes while someone's playing).

To restore: `stop.cmd`, copy the backup into `C:\Servers\Factorio Server\saves\` (the server
loads the newest file there, by date), `start.cmd`.

## Settings

Copy lines from `settings.defaults.ps1` into `settings.ps1` (gitignored) to change them:
game folder, service name, port, restart delay, steamcmd path and account, backup time and
count. Game settings (name, password, autosave, pausing) are in `server\server-settings.json`;
restart the server after editing it.

## Logs

| Log | What |
|---|---|
| `C:\Servers\Factorio Server\factorio-current.log` | Factorio's full log for the current run. The previous run is `factorio-previous.log` |
| `C:\Servers\Factorio Server\logs\console.log` | Chat, joins and leaves |
| `logs\factorio-tool.log` | Starts, stops and backups by this tool |
| `logs\install.log`, `logs\update.log` | Last install, update history |
| `logs\status.log`, `logs\test.log` | Every `status.cmd` and `test.cmd` run |

## Things that will bite you

- **Version mismatch.** A Steam client that updated overnight can't join until the server
  is updated too.
- **steamcmd `validate` resets `config-path.cfg`.** `update.cmd` fixes it. If you run
  steamcmd by hand, run `install.cmd` afterwards, or the server starts with an empty
  AppData save folder.
- **NSSM shows Running even if Factorio crash-loops.** `status.cmd` reads the game log.
- **The firewall rule is limited to `factorio.exe` at `$GameDir`.** Moving the game folder
  means re-running `install.cmd`.
