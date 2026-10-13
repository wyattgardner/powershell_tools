@echo off
rem Stores the sending account's app password for this PC, encrypted.
rem -Command, not -File: with -File, PowerShell drops the quotes and paths
rem with spaces arrive truncated at the first space.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0scripts\set-credential.ps1'"
