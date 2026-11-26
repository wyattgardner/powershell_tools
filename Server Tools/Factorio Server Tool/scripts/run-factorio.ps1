# What the NSSM service actually runs. Starts factorio.exe and waits for it.
#
# Why a wrapper: factorio.exe is a GUI-subsystem program, so run directly by NSSM it has
# no console, and NSSM's stop (Ctrl+C to the app's console) never reaches it; NSSM then
# kills it without a save. Started from this console script, Factorio attaches to our
# console. NSSM's Ctrl+C goes to the whole console: Factorio saves and exits, and this
# script ignores the Ctrl+C itself and just waits, then exits with Factorio's exit code.
# NSSM restarts it after any exit; only a service stop keeps it down.
#
# Logs to logs\service.log.

param([string]$ArgumentsOverride)    # for testing a second copy; normally unset
. (Join-Path $PSScriptRoot '_common.ps1')
$L = 'service.log'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FactorioWrapperConsole {
    [DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
}
'@

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $FactorioExe
$psi.Arguments = if ($ArgumentsOverride) { $ArgumentsOverride } else { Get-ServerArguments }
$psi.WorkingDirectory = $GameDir
$psi.UseShellExecute = $false          # inherit this console
$proc = [System.Diagnostics.Process]::Start($psi)
Write-Log "factorio.exe started (PID $($proc.Id), wrapper PID $PID)." $L

# Ignore Ctrl+C from here on. Set AFTER starting Factorio: the ignore flag is inherited
# by child processes, and Factorio must still get it.
[FactorioWrapperConsole]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null

$proc.WaitForExit()
Write-Log "factorio.exe exited (code $($proc.ExitCode))." $L
exit $proc.ExitCode
