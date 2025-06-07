# Test-GitAccess.ps1

param (
    [string]$GitRepoPath = "C:\UnityProjects\Google_ADK_Example_Game"
)

$gitExePath = "C:\Program Files\Git\bin\git.exe" 

Write-Host "--- Testing Git Access in '$GitRepoPath' ---"
Write-Host "Using Git executable: '$gitExePath'"

# --- Step 1: Check if the Git executable exists ---
if (-not (Test-Path $gitExePath)) {
    Write-Host "ERROR: Git executable NOT FOUND at '$gitExePath'. Please verify installation and path." -ForegroundColor Red
    exit 1 # Exit with an error code
}
Write-Host "SUCCESS: Git executable found."

# --- Step 2: Check if the target path exists ---
if (-not (Test-Path $GitRepoPath)) {
    Write-Host "ERROR: Target Git repository path '$GitRepoPath' NOT FOUND. Please verify the path." -ForegroundColor Red
    exit 1
}
Write-Host "SUCCESS: Target repository path found."

# --- Step 3: Change directory to the repository path ---
try {
    Set-Location $GitRepoPath -ErrorAction Stop
    Write-Host "SUCCESS: Changed directory to '$GitRepoPath'."
} catch {
    Write-Host "ERROR: Failed to change directory to '$GitRepoPath'. Message: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Step 4: Run a simple Git command and capture output ---
Write-Host "Attempting to run 'git status'..."
try {
    # Use '&' operator for external commands
    $gitStatusOutput = & $gitExePath status 2>&1
    Write-Host "--- Output of 'git status' ---"
    Write-Host ($gitStatusOutput | Out-String) # Display the full output

    # --- Step 5: Check if it's a Git repository ---
    if ($gitStatusOutput | Select-String "fatal: not a git repository" -Quiet) {
        Write-Host "FAILURE: '$GitRepoPath' is NOT a Git repository." -ForegroundColor Red
        exit 1
    }

    # --- Step 6: Get current HEAD commit (this is what was failing before) ---
    Write-Host "Attempting to get current HEAD commit with 'git rev-parse HEAD'..."
    $currentHeadCommit = ($( & $gitExePath rev-parse HEAD 2>&1) | Out-String).Trim()

    if ([string]::IsNullOrEmpty($currentHeadCommit)) {
        Write-Host "WARNING: 'git rev-parse HEAD' returned empty output. This could indicate an issue (e.g., empty repo, or still the 'dubious ownership' error if not fixed)." -ForegroundColor Yellow
        Write-Host "Raw rev-parse output: '$($( & $gitExePath rev-parse HEAD 2>&1) | Out-String)'" # Re-run to show raw output
    } else {
        Write-Host "SUCCESS: Current HEAD Commit: '$currentHeadCommit'" -ForegroundColor Green
    }
    
    Write-Host "--- Git Access Test COMPLETE ---"

} catch {
    Write-Host "ERROR: An unexpected error occurred during Git commands: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Line: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    exit 1
}