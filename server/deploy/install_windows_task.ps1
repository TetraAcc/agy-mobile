<#
.SYNOPSIS
Registers AGY Remote Hub v2.0 Windows Node Agent autostart (Task Scheduler with HKCU Run fallback).
#>
param(
    [string]$TaskName = "AGY_NodeAgent_v2",
    [string]$ConfigPath = "agent_config.json",
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 8765
)

$ErrorActionPreference = "Stop"
$DeployDir = $PSScriptRoot
$ServerDir = Split-Path -Parent $DeployDir
$PythonExe = Join-Path $ServerDir ".venv\Scripts\python.exe"
$RunnerScript = Join-Path $DeployDir "run_windows_agent.ps1"

if (-not (Test-Path $PythonExe)) {
    throw "Virtual environment python not found at: $PythonExe"
}
if (-not (Test-Path $RunnerScript)) {
    throw "Runner script not found at: $RunnerScript"
}
if ($BindHost -notmatch '^[a-zA-Z0-9.:_-]+$') {
    throw "Invalid BindHost: $BindHost"
}

$PsArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RunnerScript`" -ConfigPath `"$ConfigPath`" -BindHost $BindHost -Port $Port"
$FullCommand = "powershell.exe $PsArgs"

$registeredTask = $false
try {
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $PsArgs -WorkingDirectory $ServerDir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force -ErrorAction Stop | Out-Null
    $registeredTask = $true
    Write-Host "[+] Registered Windows Scheduled Task '$TaskName' -> $RunnerScript"
}
catch {
    Write-Host "[!] Task Scheduler registration denied/failed ($($_.Exception.Message)); falling back to HKCU Run key."
    $RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (-not (Test-Path $RunKey)) {
        New-Item -Path $RunKey -Force | Out-Null
    }
    Set-ItemProperty -Path $RunKey -Name $TaskName -Value $FullCommand -ErrorAction Stop
    Write-Host "[+] Registered HKCU Run autostart entry '$TaskName' -> $RunnerScript"
}
