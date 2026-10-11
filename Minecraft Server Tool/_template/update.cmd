@echo off
rem Updates Spigot and plugins for THIS server, with one restart. Server name =
rem this folder's name, so copies need no edits.
rem   update.cmd             update everything, including a Minecraft version jump
rem                          (backs up the world first)
rem   update.cmd -CheckOnly  just report what would happen
rem   update.cmd -NoPlugins  Spigot only
for %%I in ("%~dp0.") do set "SRV=%%~nxI"
rem -Command, not -File: with -File, PowerShell drops the quotes and a name with
rem spaces arrives truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0..\..\scripts\update-spigot.ps1' -Server '%SRV%' %*"
