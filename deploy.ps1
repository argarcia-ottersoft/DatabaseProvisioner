<#
.SYNOPSIS
    Deploys DatabaseProvisioner as a self-contained executable.
.DESCRIPTION
    Stops any running instance, publishes the app, copies the output to the deployment
    location, and starts the new instance.
.EXAMPLE
    .\deploy.ps1
#>

$DeployPath = "C:\Services\DatabaseProvisioner"

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$ProjectPath = Join-Path $ProjectRoot "DatabaseProvisioner\DatabaseProvisioner.csproj"
$StagingPath = Join-Path $ProjectRoot "publish-staging"

Write-Host "DatabaseProvisioner Deployment" -ForegroundColor Cyan
Write-Host "  Deploy path: $DeployPath" -ForegroundColor Gray
Write-Host ""

$process = Get-Process -Name "DatabaseProvisioner" -ErrorAction SilentlyContinue
if ($process) {
    Write-Host "Stopping running DatabaseProvisioner..." -ForegroundColor Yellow
    $process | Stop-Process -Force
    $process | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Write-Host "  Stopped." -ForegroundColor Green
}
else {
    Write-Host "  No running instance found." -ForegroundColor Gray
}

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

# Ensure deploy directory exists
New-Item -ItemType Directory -Path $DeployPath -Force | Out-Null

# Copy to deployment location (replace existing)
Write-Host ""
Write-Host "Deploying to $DeployPath..." -ForegroundColor Yellow
Copy-Item -Path "$StagingPath\*" -Destination $DeployPath -Recurse -Force
Write-Host "  Deploy complete." -ForegroundColor Green

# Clean up staging
Remove-Item -Path $StagingPath -Recurse -Force

Write-Host ""
$exePath = Join-Path $DeployPath "DatabaseProvisioner.exe"
Write-Host "Starting $exePath..." -ForegroundColor Yellow
Start-Process -FilePath $exePath -WorkingDirectory $DeployPath
Write-Host "  Started." -ForegroundColor Green
