@echo off
rem Read-only: show what Run-Import.bat would set on this PC, and what it would skip.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsDefaultApps.ps1" -Mode Preview -AutoClose
