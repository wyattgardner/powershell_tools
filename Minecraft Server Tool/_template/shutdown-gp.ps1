# Group Policy shutdown hook for THIS server.
#
# Why a wrapper: the Shutdown Scripts GPO passes parameters with -File semantics,
# which drops quoting, so a -Server value containing spaces arrives truncated at
# the first space. This script takes no parameters and works out the server name
# from its own folder, the same trick the .cmd launchers use.
#
# Register this file (not shutdown-minecraft.ps1) under
#   Computer Configuration > Windows Settings > Scripts > Shutdown > PowerShell Scripts
# with the Parameters box left empty.

& (Join-Path $PSScriptRoot "..\..\scripts\shutdown-minecraft.ps1") -Server (Split-Path -Leaf $PSScriptRoot)
