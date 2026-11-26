@echo off
rem Stops the server. It saves the map first, then a backup is copied.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths with
rem spaces (like "Server Tools") arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\stop.ps1'"
