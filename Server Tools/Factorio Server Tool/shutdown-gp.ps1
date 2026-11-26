# Group Policy shutdown hook: saves the map before Windows shuts down or reboots.
#
# NSSM also stops the service at shutdown, but Windows only gives services a few
# seconds. A shutdown script runs first and isn't rushed, so a big map always saves.
#
# Register this file under
#   Computer Configuration > Windows Settings > Scripts (Startup/Shutdown) > Shutdown > PowerShell Scripts
# with the Parameters box left empty.

& (Join-Path $PSScriptRoot 'scripts\stop.ps1') -NoPause -Reason 'shutdown'
