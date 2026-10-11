@echo off
rem Apply WinSettingsBackup to this PC. Asks for admin when RunAsAdmin is on in config.psd1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsSettings.ps1" -Mode Import -AutoClose
