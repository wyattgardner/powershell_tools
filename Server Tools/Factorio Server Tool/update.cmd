@echo off
rem Updates the game with steamcmd, keeping saves and settings.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths with
rem spaces (like "Server Tools") arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\update.ps1'"
