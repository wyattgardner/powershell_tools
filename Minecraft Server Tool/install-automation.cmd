@echo off
rem Re-applies settings.ps1: /update plugin, maintenance task, Windows Update policy.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths or names
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\install-automation.ps1'"
