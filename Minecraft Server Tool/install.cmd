@echo off
rem Sets up a server from install.config.ps1 (created and opened on the first run).
rem -Command, not -File: with -File, PowerShell drops the quotes and paths or names
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\install.ps1'"
