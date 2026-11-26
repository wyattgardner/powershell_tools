@echo off
rem Shows whether the server is up, who is online and the newest save and backup.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths with
rem spaces (like "Server Tools") arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\status.ps1'"
