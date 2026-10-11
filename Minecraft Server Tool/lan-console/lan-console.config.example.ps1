# Copy to lan-console.config.ps1 (gitignored) and fill in.

$serverHost = "192.168.1.50"   # the server PC's LAN IP. Give it a static IP or DHCP reservation.
$rconPort   = 25575            # that server's $RconPort
$rconPass   = "CHANGE ME"      # that server's $RconPass

# Optional: live log tail. Only works if the tools folder is shared on the network.
# Example: "\\SERVER-PC\Minecraft Server Tool\My Server\minecraft.log". Leave blank to skip.
$logPath    = ""
