@echo off
rem Registers the hourly check (as SYSTEM). install.cmd -Uninstall removes it.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\install.ps1' %*"
