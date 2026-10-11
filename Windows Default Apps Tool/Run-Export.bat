@echo off
rem Save the default apps you've changed into DefaultAppsBackup. Read-only, no admin needed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsDefaultApps.ps1" -Mode Export -AutoClose
