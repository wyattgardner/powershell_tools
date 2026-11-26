# Shared setup for every script: settings, paths, helpers. Dot-source it.

$ToolRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ToolRoot 'settings.defaults.ps1')
$userSettings = Join-Path $ToolRoot 'settings.ps1'
if (Test-Path $userSettings) { . $userSettings }

$ServerDir   = Join-Path $ToolRoot 'server'         # settings JSONs, backups (synced, gitignored)
$BackupDir   = Join-Path $ServerDir 'backups'
$LogDir      = Join-Path $ToolRoot 'logs'           # this tool's own logs
$Nssm        = Join-Path $ToolRoot 'bin\nssm.exe'
$FactorioExe = Join-Path $GameDir 'bin\x64\factorio.exe'
$SavesDir    = Join-Path $GameDir 'saves'
$GameLogDir  = Join-Path $GameDir 'logs'
$CurrentLog  = Join-Path $GameDir 'factorio-current.log'
$SettingsJson  = Join-Path $ServerDir 'server-settings.json'
$AdminlistJson = Join-Path $ServerDir 'server-adminlist.json'
$WhitelistJson = Join-Path $ServerDir 'server-whitelist.json'

function Write-Log([string]$Message, [string]$File = 'factorio-tool.log', [string]$Color) {
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path (Join-Path $LogDir $File) -Value $line -Encoding utf8
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunch the calling script elevated. -Command, not -File: -File drops quotes and
# paths with spaces (like "Server Tools") arrive truncated.
function Invoke-Elevated([string]$ScriptPath, [string]$ExtraArgs = '') {
    if (Test-Admin) { return $false }
    Write-Host 'Not elevated. Relaunching with admin rights...'
    $cmd = "& '$($ScriptPath -replace "'", "''")' $ExtraArgs"
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    return $true
}

function Pause-IfInteractive {
    if ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') { Read-Host 'Enter to close' | Out-Null }
}

# Factorio's arguments for the service. Write-data (saves, mods, config) comes from
# config-path.cfg in the game folder.
function Get-ServerArguments {
    $q = { param($p) '"' + $p + '"' }
    @(
        '--start-server-load-latest'
        '--port', $Port
        '--server-settings', (& $q $SettingsJson)
        '--server-adminlist', (& $q $AdminlistJson)
        '--use-server-whitelist'
        '--server-whitelist', (& $q $WhitelistJson)
        '--console-log', (& $q (Join-Path $GameLogDir 'console.log'))
    ) -join ' '
}

# Points Factorio's config and write-data at the game folder itself. steamcmd's
# "validate" puts Steam's version back (AppData), so update.ps1 calls this again.
function Set-ConfigPath {
    $cfg = Join-Path $GameDir 'config-path.cfg'
    $want = "config-path=__PATH__executable__/../../config`r`nuse-system-read-write-data-directories=false`r`n"
    $have = if (Test-Path $cfg) { [IO.File]::ReadAllText($cfg) } else { '' }
    if ($have -ne $want) {
        [IO.File]::WriteAllText($cfg, $want, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    }
    return $false
}

# Base game only. Space Age, Quality and Elevated Rails off even if the files appear.
function Set-ModList {
    $dir = Join-Path $GameDir 'mods'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $json = @'
{
  "mods": [
    { "name": "base", "enabled": true },
    { "name": "elevated-rails", "enabled": false },
    { "name": "quality", "enabled": false },
    { "name": "space-age", "enabled": false }
  ]
}
'@
    [IO.File]::WriteAllText((Join-Path $dir 'mod-list.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FactorioVersion {
    if (-not (Test-Path $FactorioExe)) { return $null }
    $out = & $FactorioExe --version 2>$null | Select-Object -First 1
    if ($out -match 'Version:\s*(\S+)') { return $Matches[1] }
    return $null
}

# Copies the newest save in saves\ to server\backups\<name>-<timestamp>.zip and prunes.
# Skips a file written in the last 15 s so it never grabs an autosave mid-write.
function Backup-Saves([string]$Reason = 'manual') {
    $latest = Get-ChildItem $SavesDir -Filter *.zip -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddSeconds(-15) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Write-Log "Backup ($Reason): no save found in $SavesDir" -Color Yellow; return $null }
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    $dest = Join-Path $BackupDir ('{0}-{1}-{2}.zip' -f $latest.BaseName, (Get-Date -Format 'yyyy-MM-dd_HHmm'), $Reason)
    Copy-Item $latest.FullName $dest -Force
    Write-Log "Backup ($Reason): $($latest.Name) -> $dest"
    Get-ChildItem $BackupDir -Filter *.zip | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $BackupKeep | ForEach-Object { Remove-Item $_.FullName -Force; Write-Log "Backup: pruned $($_.Name)" }
    return $dest
}

# True once factorio-current.log (rewritten at every server start) says it's in game.
function Wait-Hosting([int]$TimeoutSeconds = 120, [datetime]$Since = (Get-Date).AddSeconds(-5)) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $CurrentLog) -and (Get-Item $CurrentLog).LastWriteTime -ge $Since -and
            (Select-String -Path $CurrentLog -Pattern 'to\(InGame\)' -Quiet)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}
