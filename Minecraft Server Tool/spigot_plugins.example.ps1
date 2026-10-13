# Gameplay plugins for your servers. Optional.
#
# To use it: copy spigot_plugins.example.ps1 to spigot_plugins.ps1 and edit the copy.
# Without spigot_plugins.ps1, no plugins are installed (only the tool's own /update
# plugin). spigot_plugins.ps1 is gitignored, so your list is never committed.
#
# What happens with the list:
#   - install.cmd installs every plugin on it when it creates a new server.
#   - install-plugins.cmd "<server>" installs them on an existing server.
#   - A plugin is only installed if the server doesn't have it. Any jar whose
#     plugin.yml has the same name counts, whatever its version, so nothing is
#     ever overwritten or downgraded.
#   - Every plugin on the list also updates with update.cmd, /update and maintenance,
#     from the same source it was installed from.
#
# Each entry is keyed by the `name:` in the plugin's plugin.yml, and says where to get
# it. The kinds are the same as $PluginSources in settings.defaults.ps1:
#   geysermc : GeyserMC download API (SHA-256 checked)
#   jenkins  : latest successful build on a Jenkins CI (valid-jar check; no checksum published)
#   modrinth : newest Modrinth release for the listed loaders (SHA-512 checked)
#              Project is the slug in the plugin's URL: modrinth.com/plugin/<slug>
#
# To add a plugin: copy an entry of the matching kind and change it. To remove one,
# delete its line or put # in front. An empty list ([ordered]@{}) installs nothing.
#
# Plugins only on SpigotMC or Hangar can't be downloaded automatically (neither has a
# download API that works for this). They're listed commented out below with where to
# get them: download the jar by hand into the server's plugins folder.

$SpigotPlugins = [ordered]@{

    # Lets Bedrock players (phones, consoles, Windows 10/11 edition) join. Each server
    # gets its own Bedrock port (UDP, 19132 for the first), which also needs opening:
    # $OpenBedrockPort in install.config.ps1.
    'Geyser-Spigot' = @{ Kind = 'geysermc'; Project = 'geyser';    Platform = 'spigot'; FileName = 'Geyser-Spigot.jar' }
    # Bedrock players join without a Java account. Goes with Geyser.
    'floodgate'     = @{ Kind = 'geysermc'; Project = 'floodgate'; Platform = 'spigot'; FileName = 'floodgate-spigot.jar' }

    # Lets newer Java clients join before the server updates to their version.
    # CI builds, not releases: support for a new Minecraft version lands on CI first.
    'ViaVersion'    = @{ Kind = 'jenkins'; Base = 'https://ci.viaversion.com'; Job = 'ViaVersion';   Artifact = '^ViaVersion-[\d.]+(-SNAPSHOT)?\.jar$' }
    # Lets older Java clients join. Needs ViaVersion.
    'ViaBackwards'  = @{ Kind = 'jenkins'; Base = 'https://ci.viaversion.com'; Job = 'ViaBackwards'; Artifact = '^ViaBackwards-[\d.]+(-SNAPSHOT)?\.jar$' }

    # World backups: local zips, plus Google Drive, OneDrive or FTP if you set them up
    # in its config. Schedule its backups before maintenance runs.
    'DriveBackupV2' = @{ Kind = 'modrinth'; Project = 'drivebackupv2'; Loaders = @('spigot', 'bukkit') }

    # Harbor: skips the night when enough players (not all) are in bed.
    # SpigotMC only, so it can't be installed or updated automatically. Download it by
    # hand into the server's plugins folder:
    #   https://www.spigotmc.org/resources/60088/
}
