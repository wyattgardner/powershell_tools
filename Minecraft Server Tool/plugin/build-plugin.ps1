# Compiles ServerToolUpdater into plugin\build\ServerToolUpdater.jar.
# Compiles against the spigot-api jar BuildTools installs into the local Maven repo,
# so it needs at least one BuildTools run on this machine first. No admin needed.
# The JDK comes from settings ($JavaPath, or auto-detected).

$here   = $PSScriptRoot
$src    = Join-Path $here "ServerToolUpdater"
$build  = Join-Path $here "build"
Start-Transcript -Path (Join-Path $here "build-plugin.log") -Force | Out-Null
. (Join-Path (Split-Path -Parent $here) "scripts\_settings.ps1")

try { $jdk = Split-Path -Parent (Get-ToolJava) } catch { Write-Host $_.Exception.Message -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
if (-not (Test-Path "$jdk\javac.exe")) {
    Write-Host "No javac.exe beside $jdk\java.exe. That's a JRE; the plugin build needs a JDK." -ForegroundColor Red
    Stop-Transcript | Out-Null; exit 1
}
Write-Host "JDK: $jdk"

# Newest shaded spigot-api BuildTools has produced. Shaded = no transitive deps needed.
# BuildTools installs it into the .m2 of whoever ran it: you, or SYSTEM when the
# scheduled tasks build, so look in every profile.
$m2 = @("$env:USERPROFILE\.m2", "C:\Users\*\.m2", "$env:WINDIR\System32\config\systemprofile\.m2") |
    ForEach-Object { Join-Path $_ "repository\org\spigotmc\spigot-api" }
$api = Get-ChildItem $m2 -Recurse -Filter "spigot-api-*-shaded.jar" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $api) { Write-Host "No spigot-api jar found. Run BuildTools once first (update.cmd does)." -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
Write-Host "API: $($api.FullName)"

if (Test-Path $build) { Remove-Item $build -Recurse -Force }
$classes = Join-Path $build "classes"
New-Item -ItemType Directory $classes -Force | Out-Null

# @(...) matters: with one source file this would otherwise be a bare string, and
# splatting a string into a native command passes it one CHARACTER per argument.
$sources = @(Get-ChildItem (Join-Path $src "src") -Recurse -Filter *.java | ForEach-Object { $_.FullName })
# --release 25: the API jar is compiled for Java 25, and javac refuses to read
# class files newer than the release it targets.
& "$jdk\javac.exe" --release 25 -encoding UTF-8 -cp $api.FullName -d $classes @sources
if ($LASTEXITCODE -ne 0) { Write-Host "javac failed." -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }

Copy-Item (Join-Path $src "plugin.yml"), (Join-Path $src "config.yml") $classes
$jar = Join-Path $build "ServerToolUpdater.jar"
& "$jdk\jar.exe" --create --file $jar -C $classes .
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $jar)) { Write-Host "jar failed." -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }

Write-Host "Built $jar ($((Get-Item $jar).Length) bytes)" -ForegroundColor Green
Stop-Transcript | Out-Null
exit 0
