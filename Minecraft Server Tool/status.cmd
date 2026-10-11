@echo off
rem What's about to happen: maintenance, Windows updates, server and plugin updates.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths or names
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\status.ps1'"
