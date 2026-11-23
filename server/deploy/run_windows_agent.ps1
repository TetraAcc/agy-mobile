<#
.SYNOPSIS
Single-instance hidden runner/watchdog for AGY Remote Hub v2.0 Windows Node Agent.
#>
param(
    [string]$ConfigPath = "agent_config.json",
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 8765
)

$ErrorActionPreference = "Stop"
$DeployDir = $PSScriptRoot
$ServerDir = Split-Path -Parent $DeployDir
$PythonExe = Join-Path $ServerDir ".venv\Scripts\python.exe"
$ServerPy = Join-Path $ServerDir "server.py"
$LogsDir = Join-Path $ServerDir "logs"
$StdoutLog = Join-Path $LogsDir "agent.stdout.log"
$StderrLog = Join-Path $LogsDir "agent.stderr.log"
$LauncherLog = Join-Path $LogsDir "launcher.log"

if (-not (Test-Path $PythonExe)) {
    throw "Virtual environment python not found at: $PythonExe"
}

New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

function Write-LauncherLog {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LauncherLog -Value "[$ts] $Message" -Encoding utf8
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\AGY_NodeAgent_v2", [ref]$createdNew)
if (-not $createdNew) {
    Write-LauncherLog "Another AGY_NodeAgent_v2 instance is already running; exiting duplicate launcher."
    $mutex.Dispose()
    exit 0
}

try {
    $env:PYTHONIOENCODING = "utf-8"
    Write-LauncherLog "Launcher started (host=$BindHost port=$Port config=$ConfigPath)."

    while ($true) {
        try {
            $argsList = @(
                "-u",
                $ServerPy,
                "agent",
                "--platform", "windows",
                "--config", $ConfigPath,
                "--host", $BindHost,
                "--port", "$Port"
            )
            $proc = Start-Process `
                -FilePath $PythonExe `
                -ArgumentList $argsList `
                -WorkingDirectory $ServerDir `
                -WindowStyle Hidden `
                -RedirectStandardOutput $StdoutLog `
                -RedirectStandardError $StderrLog `
                -PassThru

            Write-LauncherLog "Started Windows Node Agent process pid=$($proc.Id)."
            $proc.WaitForExit()
            Write-LauncherLog "Windows Node Agent exited with code $($proc.ExitCode); restarting in 5s."
        }
        catch {
            Write-LauncherLog "Launcher iteration error: $($_.Exception.Message); retrying in 5s."
        }
        Start-Sleep -Seconds 5
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
