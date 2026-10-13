param(
    [string]$Server,
    [switch]$NoPause    # used by install.ps1
)

# Installs the plugins on the spigot_plugins.ps1 list that this server doesn't have
# yet. Never replaces a plugin that's already there, whatever its version. New plugins
# load at the server's next start; nothing is restarted here. Safe to re-run.
#
#   install-plugins.cmd "My Server"

if (-not $Server) {
    . (Join-Path $PSScriptRoot "_settings.ps1")
    Write-Host "Usage: install-plugins.cmd `"<server name>`"" -ForegroundColor Yellow
    Write-Host "Servers:"
    Get-ChildItem $serversDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "server.config.ps1") } |
        ForEach-Object { Write-Host "  $($_.Name)" }
    exit 1
}

$scriptPath = $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $scriptPath) "_shared.ps1")
if (-not (Test-Elevated)) { Invoke-SelfElevate $scriptPath $Server; exit }
. (Join-Path $toolsDir "_lib.ps1")

Start-Transcript -Path (Join-Path $serverDirLocal "install-plugins.log") -Append | Out-Null
Write-Host "`n=== Plugins for $ServerName ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ==="
if (-not (Test-Path (Join-Path $toolRoot "spigot_plugins.ps1"))) {
    Write-Host "No spigot_plugins.ps1. Copy spigot_plugins.example.ps1 to spigot_plugins.ps1 and edit it first." -ForegroundColor Yellow
} else {
    $added = @(Install-ListedPlugins (Get-ServerConfig $Server))
    if ($added) {
        $running = (Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -eq 'Running'
        Write-Host "`nInstalled: $($added -join ', ').$(if ($running) { ' They load at the next restart (start.cmd after stop.cmd, or the next maintenance).' })" -ForegroundColor Green
    } else { Write-Host "`nNothing to install." }
}
Stop-Transcript | Out-Null
Close-Window 15
