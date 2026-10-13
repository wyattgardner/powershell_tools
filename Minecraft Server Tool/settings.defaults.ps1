# Machine settings.
#
# To change them: copy settings.defaults.ps1 to settings.ps1 and edit the copy.
# Don't edit settings.defaults.ps1 itself; updates replace it. settings.ps1 is
# gitignored, so your values are never committed or overwritten.
#
# Defaults load first, then settings.ps1, so settings.ps1 can also hold just the
# lines you changed. Then later updates to the other defaults still reach you.
#
# Per-server settings (ports, password, heap, folder) are in each server's
# server.config.ps1.

# --- Java and builds ------------------------------------------------------------------

# java.exe the services run and the plugin builds with. Empty = auto-detect the
# newest JDK under Program Files (Adoptium, Microsoft, Oracle, Zulu), then PATH.
# Set it explicitly if you have more than one JDK installed.
$JavaPath = ""

# Where Spigot's BuildTools lives. Shared by every server: Spigot builds and plugin
# downloads are cached here, so a second server on the same version reuses them.
$BuildToolsDir = Join-Path $PSScriptRoot "BuildTools"

# --- Which server a script acts on ---------------------------------------------------

# Folder name used when a script is run without -Server. Empty = if there's exactly
# one server folder, use it; otherwise list them and stop. The .cmd launchers in each
# server folder always pass their own name, so this only matters for running the
# shared scripts by hand.
$DefaultServer = ""

# --- Spigot and plugin updates ----------------------------------------------------------

$UpdateSpigot  = $true    # build and install new Spigot builds / Minecraft versions
$UpdatePlugins = $true    # update the plugins listed in $PluginSources below

# Also update any other plugin you downloaded from Modrinth. It's recognized by its
# file hash, so there's nothing to list. Plugins from SpigotMC, Hangar or a CI
# server aren't on Modrinth's index and are left alone (list those in $PluginSources).
$AutoUpdateModrinthPlugins = $true

# Seconds of in-game warning before update.cmd or /update restarts a server.
# Skipped when nobody's online.
$UpdateCountdownSeconds = 60

# /update in-game (ops only): installs the ServerToolUpdater plugin on every server.
# Needs a JDK (javac) and one prior BuildTools run so the Spigot API is available.
$InGameUpdateCommand = $true

# Plugins that get updated automatically, keyed by the `name:` in their plugin.yml.
# Only plugins actually installed on a server are touched; anything not listed is
# left alone. To add one, copy an entry of the matching kind into settings.ps1:
#   geysermc : GeyserMC download API (SHA-256 checked)
#   jenkins  : latest successful build on a Jenkins CI (no checksum published)
#   modrinth : newest Modrinth release for the listed loaders (SHA-512 checked)
$PluginSources = [ordered]@{
    'Geyser-Spigot' = @{ Kind = 'geysermc'; Project = 'geyser';    Platform = 'spigot'; FileName = 'Geyser-Spigot.jar' }
    'floodgate'     = @{ Kind = 'geysermc'; Project = 'floodgate'; Platform = 'spigot'; FileName = 'floodgate-spigot.jar' }
    # CI builds, not Hangar releases: support for a new Minecraft version lands on CI first.
    'ViaVersion'    = @{ Kind = 'jenkins'; Base = 'https://ci.viaversion.com'; Job = 'ViaVersion';   Artifact = '^ViaVersion-[\d.]+(-SNAPSHOT)?\.jar$' }
    'ViaBackwards'  = @{ Kind = 'jenkins'; Base = 'https://ci.viaversion.com'; Job = 'ViaBackwards'; Artifact = '^ViaBackwards-[\d.]+(-SNAPSHOT)?\.jar$' }
    'DriveBackupV2' = @{ Kind = 'modrinth'; Project = 'drivebackupv2'; Loaders = @('spigot','bukkit') }
}

# --- Server logs ---------------------------------------------------------------------------

# minecraft.log (everything the server prints) is rotated when a server starts, if
# it's grown past this size: renamed to minecraft-<date>.log. 0 = never rotate.
$ServerLogRotateMB = 20
$ServerLogKeep     = 5     # rotated logs kept per server

# --- Daily maintenance ---------------------------------------------------------------------

# A scheduled task (as SYSTEM) that updates every Automatic-start server, warns
# players, and restarts. install-automation.ps1 registers or removes it to match.
$MaintenanceEnabled = $true
$MaintenanceDay     = "Daily"     # "Daily", or a weekday like "Monday"
$MaintenanceTime    = "05:00"
$MaintenanceWarnMinutes = @(15, 5, 1)   # in-game warnings, skipped if nobody's on

# Restart the servers every maintenance run even when nothing was updated.
# Long-running Spigot servers tend to benefit from it.
$MaintenanceRestartServers = $true

# --- Windows Update and reboots (off by default) ------------------------------------------

# Install pending Windows updates during maintenance, after the servers are saved
# and stopped. Off by default: it's your PC, not just a server.
$InstallWindowsUpdates = $false

# Reboot at the end of maintenance:
#   "Never"      start the servers back up instead
#   "IfRequired" reboot only if Windows says it needs one (suggested with updates on)
#   "Always"     reboot every run, for a dedicated server box
# The services are Automatic, so the servers come back after a reboot by themselves.
$RebootAfterMaintenance = "Never"

# Seconds of warning before that reboot. Windows shows a "You're about to be signed
# out" message with the restart time, so anyone at the PC can save their work.
$RebootWarnSeconds = 120

# Let install-automation.ps1 set Group Policy "Configure Automatic Updates" to
# 3 (download, notify to install), so Windows never installs or reboots on its own
# and maintenance is the only time it happens. Only makes sense with
# $InstallWindowsUpdates on; otherwise updates would never install at all.
$ManageWindowsUpdatePolicy = $false
