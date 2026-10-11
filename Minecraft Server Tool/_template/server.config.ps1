# TEMPLATE. To add a server:
#   1. Copy this whole _template folder and rename it to the server's name.
#      The folder name IS the server's identity; the .cmd launchers read it, so
#      they need no editing.
#   2. Edit the values below.
#   3. Run ..\install-server.ps1 -Server "<that folder name>" elevated.
#
# Everything must be unique per server: service name, ports, password, folder.

# Shown in the console window title.
$ServerName  = "CHANGE ME"

# Windows service name. Must be unique. No spaces, e.g. "minecraft" or "minecraft-creative".
$ServiceName = "CHANGE-ME"

# Where the server itself lives (jar, worlds, server.properties). Created if missing.
# Keep it outside this tools folder.
$ServerDir   = "C:\MinecraftServers\CHANGE ME"

# The Spigot jar in $ServerDir. The updater builds it and keeps this current;
# for a new server, leave it as is and run update.cmd.
$JarName     = "spigot-26.3.jar"

# Heap. Total across all servers must fit in RAM with room for Windows.
# 4G is plenty for a few friends; 6-8G for bigger worlds or more players.
$Heap        = "4G"

# RCON. Port must be unique. Generate a fresh password:
#   -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | % {[char]$_})
$RconHost    = "127.0.0.1"
$RconPort    = "25575"
$RconPass    = "CHANGE ME"

# Game port. Must be unique. 25565 is Minecraft's default; use 25566, 25567... for more servers.
$GamePort    = "25565"

# Logs live beside this config. Leave these as-is.
$ServerLog   = Join-Path $PSScriptRoot "minecraft.log"
$StartLog    = Join-Path $PSScriptRoot "start.log"
$ShutdownLog = Join-Path $PSScriptRoot "shutdown.log"
