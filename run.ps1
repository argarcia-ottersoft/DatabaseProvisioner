<#
.SYNOPSIS
    Starts the DatabaseProvisioner service.
.DESCRIPTION
    Stops any running DatabaseProvisioner instance, then starts the executable.
    Defaults to the directory this script lives in, so running it from the
    deployment directory requires no arguments.
.PARAMETER ServicePath
    Directory containing DatabaseProvisioner.exe. Defaults to the directory
    containing this script.
.EXAMPLE
    # From the deployment directory (no args needed)
    .\run.ps1

    # From another location, specifying the path explicitly
    .\run.ps1 -ServicePath "C:\Services\DatabaseProvisioner"
#>
param(
    [string]$ServicePath = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
$exePath = Join-Path $ServicePath "DatabaseProvisioner.exe"

if (-not (Test-Path $exePath)) {
    Write-Host "Executable not found: $exePath" -ForegroundColor Red
    exit 1
}

$process = Get-Process -Name "DatabaseProvisioner" -ErrorAction SilentlyContinue
if ($process) {
    Write-Host "Stopping running DatabaseProvisioner..." -ForegroundColor Yellow
    $process | Stop-Process -Force
    $process | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Write-Host "  Stopped." -ForegroundColor Green
}

Write-Host "Starting $exePath..." -ForegroundColor Yellow
Start-Process -FilePath $exePath -WorkingDirectory $ServicePath
Write-Host "  Started." -ForegroundColor Green
