# Folder layout, then settings: defaults from settings.defaults.ps1, then overrides
# from settings.ps1 if it exists. Dot-sourced by _shared.ps1 and _lib.ps1.

$toolRoot   = Split-Path -Parent $PSScriptRoot    # the tools folder; this file is in scripts\
$serversDir = Join-Path $toolRoot "servers"       # one folder per server
$binDir     = Join-Path $toolRoot "bin"           # nssm.exe, mcrcon.exe
$logDir     = Join-Path $toolRoot "logs"          # tool-wide logs (per-server logs live in servers\<name>\)

. (Join-Path $toolRoot "settings.defaults.ps1")
$userSettings = Join-Path $toolRoot "settings.ps1"
if (Test-Path $userSettings) { . $userSettings }

# Warn if settings.defaults.ps1 has been edited instead of settings.ps1. Only
# detectable in a git checkout: compares it to the last commit. Silent when git
# isn't installed or this isn't a repo. Once per script run.
if (-not $defaultsChecked) {
    $defaultsChecked = $true
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    # ls-files first: outside a repo, `git diff` silently becomes a plain file
    # compare and reports every file as different.
    if ($git) { & $git.Source -C $toolRoot ls-files --error-unmatch settings.defaults.ps1 2>&1 | Out-Null }
    if ($git -and $LASTEXITCODE -eq 0) {
        & $git.Source -C $toolRoot diff --quiet HEAD -- settings.defaults.ps1 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 1) {
            Write-Host "WARNING: settings.defaults.ps1 has been edited. Updates will overwrite it." -ForegroundColor Yellow
            Write-Host "         Move your changes into settings.ps1, then undo them here with:" -ForegroundColor Yellow
            Write-Host "         git checkout -- settings.defaults.ps1" -ForegroundColor Yellow
        }
        $global:LASTEXITCODE = 0
    }
}

# nssm.exe and mcrcon.exe aren't shipped in the repo; install.cmd downloads them into
# bin\. Pinned to exact builds and checked against these SHA-256 hashes,
# so a tampered or changed download is refused.
#   NSSM 2.24-101 (2017) is NSSM's newest build; there's nothing newer to update to.
$toolBinRoot = $binDir
$ToolBinaries = @(
    @{ Name = 'nssm.exe';   Url = 'https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip'
       Entry = 'nssm-2.24-101-g897c7ad/win64/nssm.exe'; Sha256 = 'EEE9C44C29C2BE011F1F1E43BB8C3FCA888CB81053022EC5A0060035DE16D848'
       Page = 'https://nssm.cc/download (the 2.24-101 pre-release, win64\nssm.exe)' }
    @{ Name = 'mcrcon.exe'; Url = 'https://github.com/Tiiffi/mcrcon/releases/download/v0.7.2/mcrcon-0.7.2-windows-x86-64.zip'
       Entry = 'mcrcon.exe'; Sha256 = 'BE44925EA0EDBD31126025980A67167D589A6EA0F0AD579EF5C740A493708E3B'
       Page = 'https://github.com/Tiiffi/mcrcon/releases/tag/v0.7.2 (windows-x86-64 zip)' }
)

# Downloads whichever of $ToolBinaries is missing. Returns $true if all are present.
function Install-ToolBinaries {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ok = $true
    foreach ($b in $ToolBinaries) {
        New-Item -ItemType Directory $toolBinRoot -Force | Out-Null
        $dest = Join-Path $toolBinRoot $b.Name
        if (Test-Path $dest) { Write-Host "  $($b.Name): present"; continue }
        $tmp = Join-Path $env:TEMP ("mst-" + [guid]::NewGuid().ToString('N') + ".zip")
        $z = $null
        try {
            Invoke-WebRequest $b.Url -OutFile $tmp -UseBasicParsing -TimeoutSec 60
            $z = [IO.Compression.ZipFile]::OpenRead($tmp)
            $entry = $z.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq $b.Entry } | Select-Object -First 1
            if (-not $entry) { throw "$($b.Entry) isn't in the download" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, "$dest.download", $true)
            $hash = (Get-FileHash "$dest.download" -Algorithm SHA256).Hash
            if ($hash -ne $b.Sha256) { Remove-Item "$dest.download" -Force; throw "checksum mismatch (got $hash)" }
            Move-Item "$dest.download" $dest -Force
            Write-Host "  $($b.Name): downloaded and verified"
        } catch {
            $ok = $false
            Write-Host "  $($b.Name): download failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Get it by hand from $($b.Page) and put it in $toolBinRoot" -ForegroundColor Yellow
        } finally {
            if ($z) { $z.Dispose() }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $ok
}

# java.exe from $JavaPath, else the newest JDK in the usual install folders, else PATH.
function Get-ToolJava {
    if ($JavaPath) {
        if (Test-Path $JavaPath) { return $JavaPath }
        throw "`$JavaPath in settings.ps1 doesn't exist: $JavaPath"
    }
    $roots = 'Eclipse Adoptium','Microsoft','Java','Zulu' | ForEach-Object { Join-Path $env:ProgramFiles $_ }
    $found = Get-ChildItem $roots -Directory -Filter 'jdk*' -ErrorAction SilentlyContinue |
        Sort-Object { [regex]::Match($_.Name, '\d+').Value -as [int] }, Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\java.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($found) { return $found }
    $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "No Java found. Install a JDK, or set `$JavaPath in settings.ps1."
}
