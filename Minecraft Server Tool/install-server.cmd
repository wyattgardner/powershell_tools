@echo off
rem Re-applies one server's server.config.ps1 to its Windows service, after you edit it.
rem   install-server.cmd "Server Name"
rem -Command, not -File: with -File, PowerShell drops the quotes and paths or names
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\install-server.ps1' -Server '%~1'"
if "%~1"=="" pause
