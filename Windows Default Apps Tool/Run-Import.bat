@echo off
rem Apply saved default apps. Sets them directly where Windows allows, walks you through Settings for the rest, or on domain-joined PCs applies them at your next sign-in (asks for admin).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsDefaultApps.ps1" -Mode Import -AutoClose
