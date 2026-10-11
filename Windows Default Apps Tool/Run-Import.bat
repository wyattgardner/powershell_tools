@echo off
rem Apply saved default apps at your next sign-in. Asks for admin when RunAsAdmin is on in config.psd1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsDefaultApps.ps1" -Mode Import -AutoClose
