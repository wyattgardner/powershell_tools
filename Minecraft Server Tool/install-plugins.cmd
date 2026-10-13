@echo off
rem Installs the plugins in spigot_plugins.ps1 that a server doesn't have yet. Never
rem replaces one that's there. Usage: install-plugins.cmd "<server name>"
rem -Command, not -File: with -File, PowerShell drops the quotes and paths or names
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\install-plugins.ps1' -Server '%~1'"
