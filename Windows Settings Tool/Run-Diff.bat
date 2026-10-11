@echo off
rem Read-only: compare WinSettingsBackup with this PC's current settings. Writes DIFF.md next to this file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsSettings.ps1" -Mode Diff -AutoClose
