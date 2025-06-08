# Test-CatFile.ps1

# --- Configuration Variables (ADJUST THESE TO YOUR ACTUAL VALUES) ---
$GitExePath = "C:\Program Files\Git\bin\git.exe"
$ProjectPath = "C:\UnityProjects\Google_ADK_Example_Game" # Your Unity project's Git repo root
$CommitHash = "9bfcedc10cd243b8d2f185a93cb57cd03d0aee60" # The specific commit hash causing issues

# --- Optional: A simple logger function for consistency ---
function Write-TestLog {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

Write-TestLog "--- Starting Git Cat-File Test Script ---"
Write-TestLog "Git Executable: $GitExePath"
Write-TestLog "Project Path: $ProjectPath"
Write-TestLog "Target Commit Hash: $CommitHash"
Write-TestLog ""

# 1. Validate paths exist
if (-not (Test-Path $GitExePath)) {
    Write-TestLog "ERROR: Git executable not found at '$GitExePath'." -Level "ERROR"
    exit 1
}
if (-not (Test-Path $ProjectPath)) {
    Write-TestLog "ERROR: Project path '$ProjectPath' does not exist." -Level "ERROR"
    exit 1
}

# 2. Change directory to the project path
try {
    Set-Location $ProjectPath -ErrorAction Stop
    Write-TestLog "SUCCESS: Changed directory to '$(Get-Location)'."
} catch {
    Write-TestLog "ERROR: Failed to change directory to '$ProjectPath'." -Level "ERROR"
    Write-TestLog "Details: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

# 3. Perform a 'git fetch' first (important for local object database)
# You might want to do a 'git fetch origin <branch_name>' for a real test,
# but 'fetch --all' is a good general test that doesn't rely on specific branch name logic here.
Write-TestLog "Attempting 'git fetch --all' to ensure local objects are updated..."
$fetchOutputLines = & $GitExePath fetch --all 2>&1
$fetchExitCode = $LASTEXITCODE

Write-TestLog "Raw 'git fetch --all' output (length: $($fetchOutputLines.Count) lines):"
Write-TestLog "--------------------------------------------------------"
Write-TestLog (($fetchOutputLines | Out-String).Trim())
Write-TestLog "--------------------------------------------------------"

if ($fetchExitCode -ne 0) {
    Write-TestLog "WARNING: 'git fetch --all' failed with exit code $fetchExitCode. This might impact cat-file." -Level "WARN"
} else {
    Write-TestLog "INFO: 'git fetch --all' completed (0 lines output is normal if no new changes)."
}

# 4. Run the 'git cat-file -t' command
Write-TestLog "`n--- Running 'git cat-file -t $CommitHash' ---"
Write-TestLog "Running command: '& \"$GitExePath\" cat-file -t \"$CommitHash\"'"

$catFileResultLines = & $GitExePath cat-file -t $CommitHash 2>&1
$catFileExitCode = $LASTEXITCODE # Capture exit code immediately

Write-TestLog "Raw 'git cat-file -t' output (length: $($catFileResultLines.Count) lines):"
Write-TestLog "--------------------------------------------------------"
Write-TestLog (($catFileResultLines | Out-String).Trim())
Write-TestLog "--------------------------------------------------------"

Write-TestLog "Last Exit Code from 'git cat-file -t': $catFileExitCode"

# 5. Evaluate the result
$commitExists = (($catFileResultLines | Out-String).Trim())

if ($catFileExitCode -ne 0) {
    Write-TestLog "ERROR: 'git cat-file -t $CommitHash' exited with a non-zero code ($catFileExitCode)." -Level "ERROR"
    Write-TestLog "This typically means the object was not found or is corrupted." -Level "ERROR"
} elseif ($commitExists -ne "commit") {
    Write-TestLog "ERROR: Commit '$CommitHash' not found or is not a valid 'commit' object." -Level "ERROR"
    Write-TestLog "Received type: '$commitExists' (Expected: 'commit')." -Level "ERROR"
} else {
    Write-TestLog "SUCCESS: Commit '$CommitHash' found and verified as a 'commit' object." -Level "INFO"
}

Write-TestLog "`n--- Git Cat-File Test Complete ---"