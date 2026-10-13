@echo off
rem Runs one check now.
rem   check.cmd             check, and email if something needs it
rem   check.cmd -DryRun     check and show what would be emailed; sends nothing
rem   check.cmd -TestEmail  send a test email
rem -Command, not -File: with -File, PowerShell drops the quotes and paths
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\check.ps1' %*"
