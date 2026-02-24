<#
.SYNOPSIS
    Deploys DatabaseProvisioner as a self-contained executable.
.DESCRIPTION
    Publishes the app, stops any running instance, copies the output (and run.ps1)
    to the deployment location, then invokes run.ps1 from there to start the service.
    To restart without redeploying, run run.ps1 from the deployment directory instead.
.EXAMPLE
    .\deploy.ps1
#>

$DeployPath = "C:\Services\DatabaseProvisioner"

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$ProjectPath = Join-Path $ProjectRoot "DatabaseProvisioner\DatabaseProvisioner.csproj"
$StagingPath = Join-Path $ProjectRoot "publish-staging"
$RunScript = Join-Path $ProjectRoot "run.ps1"

Write-Host "DatabaseProvisioner Deployment" -ForegroundColor Cyan
Write-Host "  Deploy path: $DeployPath" -ForegroundColor Gray
Write-Host ""

# Clean staging folder
if (Test-Path $StagingPath) {
    Remove-Item -Path $StagingPath -Recurse -Force
}

# Publish
Write-Host ""
Write-Host "Publishing (self-contained, win-x64)..." -ForegroundColor Yellow
dotnet publish $ProjectPath -c Release -r win-x64 --self-contained true -o $StagingPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "Publish failed." -ForegroundColor Red
    exit 1
}
Write-Host "  Publish complete." -ForegroundColor Green

# Stop running instance before deploying (must happen before file copy)
$process = Get-Process -Name "DatabaseProvisioner" -ErrorAction SilentlyContinue
if ($process) {
    Write-Host ""
    Write-Host "Stopping running DatabaseProvisioner..." -ForegroundColor Yellow
    $process | Stop-Process -Force
    $process | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Write-Host "  Stopped." -ForegroundColor Green
}

# Ensure deploy directory exists
New-Item -ItemType Directory -Path $DeployPath -Force | Out-Null

# Copy to deployment location (replace existing)
Write-Host ""
Write-Host "Deploying to $DeployPath..." -ForegroundColor Yellow
Copy-Item -Path "$StagingPath\*" -Destination $DeployPath -Recurse -Force
Copy-Item -Path $RunScript -Destination $DeployPath -Force
Write-Host "  Deploy complete." -ForegroundColor Green

# Clean up staging
Remove-Item -Path $StagingPath -Recurse -Force

# Start via run.ps1 in the deployment directory
Write-Host ""
& "$DeployPath\run.ps1" -ServicePath $DeployPath
