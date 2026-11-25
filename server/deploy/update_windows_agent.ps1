<#
.SYNOPSIS
One-click update script for AGY Remote Hub Windows Node Agent.
Pulls latest main via fast-forward, syncs Python deps if needed, restarts the
running agent process (re-launched automatically by run_windows_agent.ps1),
and verifies the updated version.
#>
param(
    [string]$HealthUrl = "http://127.0.0.1:8765/internal/health",
    [string]$TaskName = "AGY_NodeAgent_v2"
)

$ErrorActionPreference = "Stop"
$DeployDir = $PSScriptRoot
$ServerDir = Split-Path -Parent $DeployDir
$RepoDir = Split-Path -Parent $ServerDir
$PythonExe = Join-Path $ServerDir ".venv\Scripts\python.exe"
$PyProject = Join-Path $ServerDir "pyproject.toml"

Write-Host "[1/4] Checking git status in $RepoDir ..."
$dirty = git -C $RepoDir status --porcelain --untracked-files=no
if ($dirty) {
    throw "Working tree has uncommitted changes. Aborting update to avoid overwriting local files."
}

$depsBefore = ""
if (Test-Path $PyProject) {
    $depsBefore = (Get-FileHash -Algorithm SHA256 $PyProject).Hash
}

Write-Host "[2/4] Pulling latest commits (git pull --ff-only) ..."
git -C $RepoDir fetch --quiet origin
git -C $RepoDir pull --ff-only

$depsAfter = ""
if (Test-Path $PyProject) {
    $depsAfter = (Get-FileHash -Algorithm SHA256 $PyProject).Hash
}
if ($depsBefore -ne $depsAfter -and (Test-Path $PythonExe)) {
    Write-Host "[2.5/4] pyproject.toml changed; installing Python dependencies ..."
    & $PythonExe -m pip install -e $ServerDir --quiet
}

Write-Host "[3/4] Restarting Windows Node Agent process ..."
$procs = Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -like "*server.py agent*"
}
if ($procs) {
    foreach ($p in $procs) {
        Write-Host "  Stopping old agent PID=$($p.ProcessId)"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  No active agent process found; starting scheduled task $TaskName ..."
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

Write-Host "[4/4] Waiting for new agent to come online ..."
$ok = $false
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 3
        Write-Host "Update complete! Node Agent version: $($resp.version) (engine_alive=$($resp.engine_alive))"
        $ok = $true
        break
    } catch {
        Write-Host "  Waiting ($($i + 1)/12)..."
    }
}

if (-not $ok) {
    Write-Warning "Agent did not respond at $HealthUrl yet. Check server\logs\agent.stderr.log or Scheduled Task '$TaskName'."
}
