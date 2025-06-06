# Define the stop file path
$stopFile = "$env:TEMP\unity_listener_stop.flag"
$serviceName = "UnityBuildService"

Write-Host "=== [1] Removing old stop file (if exists)..."
Remove-Item $stopFile -ErrorAction SilentlyContinue

Write-Host "=== [2] Starting service: $serviceName..."
nssm start $serviceName
Start-Sleep -Seconds 10  # Give it a few seconds to start and log

Write-Host "=== [3] Creating stop file to trigger graceful shutdown..."
New-Item $stopFile -Force | Out-Null

Write-Host "=== [4] Waiting for script to detect stop file and shut down..."
Start-Sleep -Seconds 10

Write-Host "=== [5] Stopping service (should be graceful)..."
nssm stop $serviceName

Write-Host "=== [6] Checking if stop file still exists..."
if (Test-Path $stopFile) {
    Write-Host "Stop file still exists. Removing it manually."
    Remove-Item $stopFile -Force
} else {
    Write-Host "Stop file successfully removed by script."
}

Write-Host "`n=== Test complete. Check Unity log for shutdown confirmation. ==="
