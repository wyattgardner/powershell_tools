@echo off
rem Tests crash restart, clean stop (save + backup) and start. Asks for admin.
rem Players get disconnected for about a minute. Results in logs\test.log.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths with
rem spaces (like "Server Tools") arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\test.ps1'"
