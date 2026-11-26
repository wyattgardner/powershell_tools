@echo off
rem Installs or re-applies the service, firewall rule and nightly backup. Asks for admin.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths with
rem spaces (like "Server Tools") arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\install.ps1'"
