# Install settings: what install.cmd sets up.
#
# The first time you run install.cmd it copies this file to install.config.ps1
# (gitignored) and opens it. Edit the copy, save, and run install.cmd again.
# Don't edit install.config.defaults.ps1 itself; updates replace it.
#
# Run install.cmd once per server. Running it again for a server that already
# exists finishes any steps that didn't complete and leaves its config alone.

# --- The server -----------------------------------------------------------------------

# Server name. Also the name of its folder in the tools folder, so keep it to
# characters Windows allows in folder names.
$ServerName = "My Server"

# You must set this to $true: it means you accept the Minecraft EULA,
# https://aka.ms/MinecraftEULA. The server won't start without it.
$AcceptEula = $false

# Where the server itself lives (jar, worlds, server.properties).
# Empty = C:\MinecraftServers\<ServerName>.
# To bring in an existing server, point this at its folder. A spigot*.jar in it is
# used as-is and updated from there.
$ServerDir = ""

# Memory for the server. 4G suits a few friends; 6-8G for bigger worlds or more
# players. Leave several GB for Windows, and for any other servers.
$Heap = "4G"

# Windows service name. Empty = "minecraft-" plus the server name, lowercased.
$ServiceName = ""

# Ports. Empty = the first free ones: game from 25565, RCON from 25575, and Bedrock
# (UDP, for Geyser) from 19132.
$GamePort    = ""
$RconPort    = ""
$BedrockPort = ""

# RCON password. Empty = a random 24-character one.
$RconPass = ""

# --- What the installer does ------------------------------------------------------------

# Install Eclipse Temurin JDK 25 with winget if no JDK is found.
$InstallJava = $true

# Build Spigot and start the server at the end of install (a few minutes).
$BuildAndStart = $true

# Windows Firewall rules letting players in. Players outside your network also
# need the port forwarded on your router; the installer can't do that.
$OpenGamePort    = $true
$OpenBedrockPort = $false    # the server's Bedrock port (UDP), only if you'll run Geyser for Bedrock players

# Run install-automation (in-game /update and the maintenance task, following
# settings.ps1). Set those machine-wide options BEFORE installing; see README.
$InstallAutomation = $true

# Shortcuts.
$DesktopShortcuts = $true    # Desktop\Minecraft Servers\<ServerName>\ with console, start, stop
$StartupConsole   = $false   # open this server's console window at every login

# Open the Group Policy editor at the end, with the shutdown script path on the
# clipboard, so you can register it (the one manual step; see README).
$OpenShutdownScriptSetup = $true
