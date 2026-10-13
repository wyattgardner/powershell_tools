# Minecraft Server Tool

PowerShell tooling for running one or more Spigot servers on a Windows PC as proper
Windows services, using [NSSM](https://nssm.cc).

- Servers start at boot, before anyone logs in, and restart themselves if they crash.
- Shutting down or rebooting Windows saves the world first.
- `update.cmd`, or `/update` in-game, updates Spigot and your plugins with **one**
  restart, and rolls everything back if the server doesn't come up right.
- Optional daily maintenance: updates, a warning to players, a restart, and
  optionally Windows updates and a reboot.
- A console window with the live log where you can type commands, no admin needed.

Everything machine-specific lives in files you own: `settings.ps1` for the machine,
`install.config.ps1` for the installer, and `server.config.ps1` for each server. None
are tracked by git.


## Requirements

- Windows 10 or 11 (Windows PowerShell 5.1 is built in)
- Admin rights on the PC
- About 2 GB free for BuildTools, plus your worlds
- Internet access during install

The installer gets everything else: [NSSM](https://nssm.cc) and
[mcrcon](https://github.com/Tiiffi/mcrcon) (pinned versions, checksum-verified),
and a JDK 25 via winget if you don't have one.

## Install

1. Put the folder somewhere permanent, e.g. `C:\MinecraftServerTool`. Spaces in the
   path are fine. The services and scheduled tasks point at this folder, so moving
   it later means re-running the install (see
   [Moving the tools folder](#moving-the-tools-folder)).
2. Optional: change machine-wide settings first, like Windows updates, reboots, or
   the maintenance time. See [Settings](#settings).
3. Run **`install.cmd`**. The first run creates `install.config.ps1` and opens it.
4. Set at least `$ServerName` and `$AcceptEula = $true`, save, and run
   **`install.cmd`** again. It asks for admin and takes a few minutes.
5. Register the shutdown script when it asks you to (see below). It's the one step
   the installer can't do for you.

That's it. The server is running, starts with Windows, and has `console.cmd`,
`start.cmd`, `stop.cmd`, and `update.cmd` in its folder (and on your desktop, by
default).

For another server, change `$ServerName` in `install.config.ps1` and run
`install.cmd` again. Ports, service name, and password are picked automatically
so they don't clash. Re-running it for a server that already exists finishes any
steps that didn't complete, without touching its config.

### What the installer does

1. Downloads `nssm.exe` and `mcrcon.exe`, and installs a JDK if none is found.
2. Creates the server's folder from `_template\` and fills in `server.config.ps1`.
3. Accepts the EULA, installs the Windows service, sets up `server.properties` for
   RCON, and blocks the RCON port from the internet.
4. Adds firewall rules so players can connect.
5. Builds Spigot with BuildTools, starts the server, and checks it came up.
6. Sets up `/update` and daily maintenance, following your settings.
7. Makes shortcuts.
8. Opens the Group Policy editor for the shutdown script.

Everything is logged to `logs\install.log`.

### Install options

All in `install.config.ps1`. Empty values mean "pick for me".

| Option | Default | What it does |
|---|---|---|
| `$ServerName` | `My Server` | Server name, and its folder name |
| `$AcceptEula` | `$false` | Must be `$true`: you accept the [Minecraft EULA](https://aka.ms/MinecraftEULA) |
| `$ServerDir` | `C:\MinecraftServers\<name>` | Where the jar and worlds live. Point it at an existing server to bring it in; its `spigot*.jar` is used. |
| `$Heap` | `4G` | Server memory. 6-8G for bigger worlds or more players. |
| `$ServiceName` | `minecraft-<name>` | Windows service name |
| `$GamePort` / `$RconPort` | first free from 25565 / 25575 | Ports |
| `$RconPass` | random | RCON password |
| `$InstallJava` | `$true` | Install Temurin JDK 25 with winget if no JDK is found |
| `$BuildAndStart` | `$true` | Build Spigot and start the server at the end |
| `$OpenGamePort` | `$true` | Firewall rule for the game port |
| `$OpenBedrockPort` | `$false` | Firewall rule for UDP 19132, if you'll add Geyser |
| `$InstallAutomation` | `$true` | Set up `/update` and maintenance |
| `$DesktopShortcuts` | `$true` | `Desktop\Minecraft Servers\<name>\` with console, start, stop, update |
| `$StartupConsole` | `$false` | Open the console window at every login |
| `$OpenShutdownScriptSetup` | `$true` | Open gpedit with the shutdown script path on the clipboard |

Everything about a server can be changed later in its `server.config.ps1`; run
`install-server.cmd "<name>"` afterwards to apply it.

### The shutdown script

This is what saves the world when Windows shuts down or reboots. Group Policy
scripts can't be registered reliably from a script, so the installer opens the
editor and puts the path on your clipboard:

1. Computer Configuration → Windows Settings → Scripts (Startup/Shutdown) →
   **Shutdown** → **PowerShell Scripts** tab → Add.
2. Script name: paste (`<tools folder>\servers\<server>\shutdown-gp.ps1`). Leave
   **Parameters empty**.
3. One entry per server.

Windows Home has no Group Policy editor. There, use `stop.cmd` before shutting
down or rebooting.

### Playing over the internet

The installer opens the game port in Windows Firewall, which covers your own
network. For friends elsewhere, forward the game port (TCP, plus UDP 19132 for
Geyser) on your router to this PC. **Never forward the RCON port.**

## Everyday use

Each server's folder, `servers\<server>\`, has:

- `console.cmd`: live log; type commands. No admin needed. Press **Q** to close
  (not `exit`, which gets sent to the server). Survives restarts: it waits and
  reconnects. A Startup-folder shortcut to it is handy and safe.
- `start.cmd`: start, and wait until the server actually reports it's up.
- `stop.cmd`: save, stop, and *keep it stopped*. Use this before editing server files.
- `update.cmd`: update Spigot and plugins now (see below).

Typing `stop` in the console is a **restart** (the service brings it back in ~5s).
`stop.cmd` is what keeps it down.

If a file in the server folder won't save and Windows claims you lack permission,
it's almost always a lock: the running server holds world files and
`logs\latest.log` open. Stop it first.

`status.cmd` shows what's coming: next maintenance, pending Windows updates and
which can force a reboot, and whether each server has an update waiting. Run it as
admin to see the scheduled tasks.

One-off command without the console:

```powershell
bin\mcrcon.exe -H 127.0.0.1 -P <rcon port> -p <rcon password> "list"
```

## Settings

Defaults are in `settings.defaults.ps1`; override any of them in `settings.ps1`.
The suggested defaults suit a PC you also use for other things; the last column
is what a dedicated, always-on server box might use.

| Setting | Default | What it does | Dedicated box |
|---|---|---|---|
| `$JavaPath` | auto-detect | `java.exe` for the services and builds. Set it if you have more than one JDK. | your JDK |
| `$BuildToolsDir` | `.\BuildTools` | Shared BuildTools folder; Spigot builds and plugin downloads are cached here | same |
| `$DefaultServer` | only server | Server used when you run a shared script without `-Server` | same |
| `$UpdateSpigot` | `$true` | Update Spigot builds and Minecraft versions | same |
| `$UpdatePlugins` | `$true` | Update plugins at all | same |
| `$AutoUpdateModrinthPlugins` | `$true` | Update any plugin from Modrinth, found by file hash | same |
| `$UpdateCountdownSeconds` | `60` | In-game warning before an update restart (skipped if nobody's on) | same |
| `$InGameUpdateCommand` | `$true` | Install the `/update` plugin (ops only) | same |
| `$PluginSources` | Geyser, Floodgate, ViaVersion, ViaBackwards, DriveBackupV2 | Which plugins auto-update, and from where | same |
| `$MaintenanceEnabled` | `$true` | Scheduled maintenance task | same |
| `$MaintenanceDay` / `$MaintenanceTime` | `Daily` / `05:00` | When it runs | same |
| `$MaintenanceWarnMinutes` | `15, 5, 1` | In-game warnings before the restart | same |
| `$MaintenanceRestartServers` | `$true` | Restart even when nothing was updated | same |
| `$InstallWindowsUpdates` | `$false` | Install Windows updates during maintenance, with the servers stopped | `$true` |
| `$RebootAfterMaintenance` | `"Never"` | `"Never"`, `"IfRequired"`, or `"Always"` | `"Always"` |
| `$RebootWarnSeconds` | `120` | Warning before that reboot. Windows' "You're about to be signed out" message shows the restart time. | same |
| `$ManageWindowsUpdatePolicy` | `$false` | Stop Windows installing or rebooting on its own, so maintenance is the only time it happens | `$true` |
| `$ServerLogRotateMB` / `$ServerLogKeep` | `20` / `5` | Rotate `minecraft.log` at server start past this size; old logs kept | same |

The Windows options are off by default because they change how your whole PC
updates, not just the servers. Turn them on together. With
`$ManageWindowsUpdatePolicy` on and `$InstallWindowsUpdates` off, updates would never
install, so `install-automation.cmd` refuses that combination.

## Updating Spigot and plugins

```
update.cmd              update everything, including a Minecraft version jump
update.cmd -CheckOnly   just say what it would do
update.cmd -NoPlugins   Spigot only
/update                 same as update.cmd, except a Minecraft version jump needs /update confirm
```

What it does, in order: updates BuildTools itself if there's a newer build, works out
targets, builds Spigot and downloads plugins **while the server stays up**, warns
players, stops, swaps, starts, and checks that the server booted on the new Spigot
build and that every updated plugin enabled. If anything didn't, **all of it** goes
back as it was. Previous jars are kept in `<ServerDir>\old jars\` and
`<ServerDir>\old plugins\<date>\`. Progress is announced in chat and logged to
`servers\<server>\update.log`.

**It doesn't use `--rev latest`.** Spigot's `latest.json` can lag Mojang by weeks. It
asks Mojang for the actual latest release, then checks Spigot has published it. If
Spigot hasn't yet, it only looks for newer builds of the version you're on.

**A Minecraft version jump permanently upgrades the world**, and can break Bedrock
players until Geyser catches up. So the updater first takes a full backup to
`<ServerDir>\manual backups\` (never pruned), and `/update` asks for
`/update confirm` before doing it. `update.cmd` and maintenance apply jumps without
asking.

It also skips Spigot if the new version needs a Java the service doesn't run. Only
one update runs at a time, since servers share BuildTools.

### Which plugins update

Two ways, both only touching plugins actually installed on a server:

**Any plugin you got from Modrinth, automatically.** Each jar is looked up on
[Modrinth](https://modrinth.com) by its file hash, so there's no list to keep. If
Modrinth knows it and has a newer Spigot/Bukkit release, it's updated. Plugin
authors' Minecraft version tags tend to lag (a plugin tagged up to 26.2 usually runs
fine on 26.3), so the tags aren't used as a strict filter. An update is skipped only
if every version it's tagged for is newer than your server, and an older version
is never installed over a newer one. Turn it off with `$AutoUpdateModrinthPlugins`.

**Plugins listed in `$PluginSources`**, matched by the `name:` in each jar's
`plugin.yml`. This is for plugins that aren't on Modrinth, or where another source
is better. The list takes priority over the Modrinth lookup.

| Kind | Source | Checked by |
|---|---|---|
| `geysermc` | GeyserMC download API (Geyser, Floodgate) | SHA-256 |
| `jenkins` | Latest successful build on a Jenkins CI (ViaVersion and ViaBackwards: new Minecraft support lands on CI before releases) | none published; build number recorded in `<ServerDir>\plugin-versions.json` |
| `modrinth` | Newest Modrinth release for the listed loaders | SHA-512 |

Plugins from SpigotMC's resource pages or Hangar can't be updated automatically:
neither offers a way to look a jar up by hash. Update those by hand, or list them in
`$PluginSources` if they also publish to Modrinth or a CI server.

To add a plugin to the list, copy the whole `$PluginSources` block into
`settings.ps1` and add an entry of the matching kind.

### What gets checksum-verified

| Download | Check |
|---|---|
| `nssm.exe`, `mcrcon.exe` | Pinned SHA-256 in `scripts\_settings.ps1` |
| JDK (winget) | winget's own installer hash check |
| Geyser, Floodgate | SHA-256 from GeyserMC |
| Modrinth plugins | SHA-512 from Modrinth |
| BuildTools.jar, ViaVersion/ViaBackwards CI builds | HTTPS and a valid-jar check only: these Jenkins servers publish no usable checksum |
| Spigot builds | SHA-256 recorded at build time, checked before reusing a cached build and after copying it into the server |

Every plugin swap also checks the copied jar against the download before starting
the server.

### Why `/update` goes through a scheduled task

The update has to stop the server, and stopping the service kills the server's whole
process tree, so anything the plugin launched directly would die halfway through.
The `ServerToolUpdater` plugin runs `schtasks /run /tn "Minecraft Update - <server>"`
instead. The server runs as LocalSystem, which may start any task. The plugin's
source is in `plugin\`; the installer builds and installs it.

## Daily maintenance

Runs as SYSTEM at `$MaintenanceTime`:

1. While the servers are still up: update BuildTools, build Spigot, download plugins.
2. Warn players at `$MaintenanceWarnMinutes` (skipped if nobody's online).
3. Apply each server's updates: one stop, swap, start, and verify per server.
4. Save and stop every server.
5. Install Windows updates, if `$InstallWindowsUpdates` is on.
6. Reboot if `$RebootAfterMaintenance` says so; otherwise start the servers back up.

If nothing needs updating and `$MaintenanceRestartServers` is off, it stops after
step 1 and nobody gets kicked. Servers whose service is set to Manual start are
left alone, which is handy for a test server. Logged to `logs\maintenance.log`.

`maintenance.cmd -DryRun` rehearses it: it checks for updates and prints the
messages it would send, then stops before touching anything. `-NoReboot` does
everything else but never reboots.

## Backups

- **Version jumps**: automatic, to `<ServerDir>\manual backups\`, as above.
- **Everything else**: bring your own. [DriveBackupV2](https://modrinth.com/plugin/drivebackupv2)
  works well (local zips, plus Google Drive/OneDrive/FTP if you want) and is in the
  default `$PluginSources`. Schedule its backups before maintenance runs. Its
  schedule uses a fixed UTC offset, so it shifts an hour across daylight saving.

## Adding more servers

Change `$ServerName` in `install.config.ps1` and run `install.cmd` again. It picks a
service name, ports, and password that don't clash with your other servers. Then
register the new server's shutdown script too.

If you set ports by hand, keep them unique: a port used twice fails at startup, not
at install, and the second server just sits there restarting.

## Using the console from another PC

Copy the `lan-console\` folder to the other PC (the installer puts `mcrcon.exe` in
it). There, copy `lan-console.config.example.ps1` to `lan-console.config.ps1`, fill
in the server PC's LAN IP, RCON port, and password, then run `lan-console.cmd`. Give the server PC a static IP or DHCP reservation so
the address doesn't change.

## Layout

```
<tools folder>\
   install.cmd                       set up a server (start here)
   install-server.cmd                re-apply a server's server.config.ps1
   install-automation.cmd            re-apply settings: /update, maintenance, Windows Update
   status.cmd                        what's about to happen
   maintenance.cmd                   run maintenance now (-DryRun to rehearse)
   install.config.defaults.ps1       install options (copied to install.config.ps1)
   settings.defaults.ps1             machine settings (copy to settings.ps1 to change)
   scripts\                          the PowerShell behind the .cmd files
   bin\                              nssm.exe, mcrcon.exe (downloaded by install.cmd)
   lan-console\                      console from another PC; copy the whole folder
   plugin\                           ServerToolUpdater source (the /update plugin)
   _template\                        what each server folder starts from
   logs\                             install, maintenance, status logs
   BuildTools\                       Spigot builds and plugin cache (default location)
   servers\                          one folder per server
      <server>\
         server.config.ps1           name, service, ports, password, paths
         console.cmd start.cmd stop.cmd update.cmd shutdown-gp.ps1
         minecraft.log start.log shutdown.log update.log
```

Your files (`settings.ps1`, `install.config.ps1`, `servers\`) and everything
downloaded or generated (`bin\`, `logs\`, `BuildTools\`) are gitignored.

## Logs and crashes

- `minecraft.log` in the server's folder: everything the server printed. When a
  server starts and its log is over `$ServerLogRotateMB` (20 MB), it's renamed to
  `minecraft-<date>.log`; the newest `$ServerLogKeep` (5) are kept.
- `start.log` / `shutdown.log` / `update.log`: one block per run, with timings.
- The server's own `logs\*.gz`: Spigot rotates these per session.
- Crashes: Spigot writes `crash-reports\`, the JVM writes `hs_err_pid*.log` into
  `$ServerDir`, and `minecraft.log` catches anything printed before the JVM dies.
  That last one is the only record of a JVM that dies before Spigot's logging
  starts, so keep it after a crash.

`log4j2.xml` gives the logs full ISO timestamps (`2026-01-17T02:19:24` instead of
`[02:19:24]`). `start-minecraft.ps1` relies on them to tell this boot's "Done" line
from an older one; without them it times out after 3 minutes on a healthy server.

## Things that will bite you

**Don't enable NSSM's own log rotation.** In A/B testing on NSSM 2.24-101, with
`AppRotate*` set, NSSM didn't restart the server after it exited: no event-log
entry, no restart, and the service sat marked **Running with no server behind it**.
The root cause isn't known. The tool rotates `minecraft.log` itself instead,
while the server is stopped (see above).

**Never start a server any other way as well** (Startup folder, Task Scheduler, a
`.bat`). That launches a second copy, which fails only because the first one holds
the world lock. A shortcut to `console.cmd` is fine; it only attaches.

**`nssm stop` hangs when the server is paused** (empty for 60s). Use `stop.cmd`,
which goes through RCON.

**Use `-Command`, not `-File`, when passing `-Server` to these scripts.** With
`-File`, PowerShell drops the quoting and `-Server "My Server"` arrives as `My`.
Same reason the shutdown script is a parameterless wrapper per server.

**Don't set "maximum wait time for Group Policy scripts".** The default is 600s;
the commonly suggested 60 would *reduce* it.

**Windows Update policy.** With `$ManageWindowsUpdatePolicy` on, if the maintenance
task breaks, updates quietly stop going in. `status.cmd` shows the task's last run
and result. The setting lives in the local GPO's `Registry.pol`; writing the
registry value alone gets reverted on the next policy refresh, which is why
`install-automation.ps1` patches `Registry.pol` (with a backup beside it). If the
value was never set in gpedit, it tells you to set it there once by hand.

## Security

RCON listens on all network interfaces (Minecraft has no option to bind it to one),
and the protocol is unencrypted. The installer adds a firewall rule blocking
each RCON port from internet addresses; Block beats Allow in Windows Firewall, so it
holds even if Java has a broad Allow rule. LAN access still works, so the password
crosses your LAN in clear text. Use a unique random password per server, and never
port-forward RCON.

## Moving the tools folder

The services, scheduled tasks, shutdown scripts, and any shortcuts point at the
tools folder. After moving or renaming it:

1. Stop the servers (`stop.cmd`).
2. Run `install-server.cmd "<name>"` for each server.
3. Run `install-automation.cmd`.
4. Update the shutdown script paths in gpedit, and fix any shortcuts.

## Credits

Downloaded by the installer, not included in the repo:

- [NSSM](https://nssm.cc) 2.24-101 by Iain Patterson, public domain
- [mcrcon](https://github.com/Tiiffi/mcrcon) by Tiiffi, zlib license
- [Spigot BuildTools](https://www.spigotmc.org/wiki/buildtools/)
