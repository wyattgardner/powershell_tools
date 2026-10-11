@echo off
rem Save the settings you've changed into WinSettingsBackup. Asks for admin when RunAsAdmin is on in config.psd1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsSettings.ps1" -Mode Export -AutoClose
