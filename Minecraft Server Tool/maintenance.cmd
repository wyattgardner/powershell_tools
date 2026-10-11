@echo off
rem Runs maintenance now. maintenance.cmd -DryRun rehearses it without changing anything.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths or names
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\maintenance.ps1' %*"
pause
