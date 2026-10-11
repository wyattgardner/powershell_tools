@echo off
rem Server name = the name of THIS folder, so copying this folder for a new
rem server needs no edits here.
for %%I in ("%~dp0.") do set "SRV=%%~nxI"
rem -Command, not -File: with -File, PowerShell drops the quotes and a name with
rem spaces arrives truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0..\..\scripts\start-minecraft.ps1' -Server '%SRV%'"
