# Loaded by every script. Resolves which server we're acting on and pulls in its
# config, so the scripts themselves contain no server-specific values.
#
# Each script takes -Server <name>, matching a folder in servers\ (one with a
# server.config.ps1 in it).

param()  # placeholder; callers dot-source this after setting $Server

$toolsDir   = Split-Path -Parent $MyInvocation.MyCommand.Path    # scripts\
. (Join-Path $toolsDir "_settings.ps1")                         # $serversDir, $binDir, ...
$nssm       = Join-Path $binDir "nssm.exe"
$mcrcon     = Join-Path $binDir "mcrcon.exe"
foreach ($exe in $nssm, $mcrcon) {
    if (-not (Test-Path $exe)) {
        Write-Host "$(Split-Path -Leaf $exe) is missing from bin\. Run install.cmd; it downloads it." -ForegroundColor Red
        if ([Environment]::UserInteractive) { Start-Sleep -Seconds 20 }
        throw "Missing $(Split-Path -Leaf $exe)."
    }
}

$serverFolders = @(Get-ChildItem $serversDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "server.config.ps1") } |
    ForEach-Object Name)

# No -Server: settings' $DefaultServer, else the only server there is.
if (-not $Server) { $Server = $DefaultServer }
if (-not $Server -and $serverFolders.Count -eq 1) { $Server = $serverFolders[0] }

$serverDirLocal = if ($Server) { Join-Path $serversDir $Server } else { $null }
$configPath     = if ($Server) { Join-Path $serverDirLocal "server.config.ps1" } else { $null }
if (-not $configPath -or -not (Test-Path $configPath)) {
    if ($Server) { Write-Host "No config found for server '$Server'." -ForegroundColor Red; Write-Host "Expected: $configPath" }
    else { Write-Host "Which server? Pass -Server `"<folder name>`", or set `$DefaultServer in settings.ps1." -ForegroundColor Red }
    Write-Host "Servers in $serversDir :"
    if ($serverFolders) { $serverFolders | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  none yet. Run install.cmd to make one." }
    if ([Environment]::UserInteractive) { Start-Sleep -Seconds 20 }
    # throw, not exit: this file is dot-sourced, and exit would only leave this file,
    # letting the calling script carry on with no server.
    throw "No server selected."
}
# Same reason for every other failure below: throw, not exit.

. $configPath

foreach ($required in 'ServerName','ServiceName','ServerDir','RconPort','RconPass','ServerLog') {
    if (-not (Get-Variable -Name $required -ValueOnly -ErrorAction SilentlyContinue)) {
        Write-Host "Config $configPath is missing `$$required." -ForegroundColor Red
        if ([Environment]::UserInteractive) { Start-Sleep -Seconds 20 }
        throw "Server config incomplete."
    }
}

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunches the calling script elevated, preserving -Server.
# Uses -Command rather than -File: with -File, PowerShell drops the quoting and a
# server name containing spaces arrives truncated at the first space.
function Invoke-SelfElevate($scriptPath, $serverName) {
    Write-Host "Not elevated. Relaunching with admin rights..."
    $cmd = "& '$scriptPath' -Server '$serverName'"
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd
    )
}

function Get-Jvm {
    $w = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).ProcessId
    if (-not $w -or $w -eq 0) { return $null }
    (Get-CimInstance Win32_Process -Filter "Name='java.exe' AND ParentProcessId=$w" -ErrorAction SilentlyContinue).ProcessId
}

# Every exit path ends the same way. Failures get longer so the error stays readable.
# Skipped when nobody's watching: Group Policy runs the shutdown script during
# Windows shutdown, where sleeping would just delay every reboot.
# Also skipped when a calling script sets $NoPause (install.ps1 does, for everything
# it runs).
function Close-Window([int]$seconds = 10) {
    if (-not [Environment]::UserInteractive -or $NoPause) { return }
    Write-Host ""
    Write-Host "Done. Closing in $seconds seconds..." -ForegroundColor Green
    Start-Sleep -Seconds $seconds
}
