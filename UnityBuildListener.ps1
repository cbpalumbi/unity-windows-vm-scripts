# UnityBuildListener.ps1
# This script listens for Pub/Sub messages and triggers Unity builds.

# --- Configuration Variables ---
$Script:SubscriptionPath = "projects/cool-ruler-461702-p8/subscriptions/unity-build-subscription"
$Script:GCSBucket = "gs://my_adk_unity_hackathon_builds_2025"
$Script:UnityProjectPath = "C:\UnityProjects\Google_ADK_Example_Game"
$Script:UnityEditorPath = "C:\Program Files\Unity\Hub\Editor\6000.0.50f1\Editor\Unity.exe"
$Script:UnityLogFilePath = "C:\Users\unityadmin\Documents\UnityLogs\unity_build_log.txt"
$Script:BuildOutputBaseFolder = "C:\Users\unityadmin\Documents\UnityBuilds" # Base folder for builds
$Script:GameBuildMethod = "BuildScript.PerformBuild" # The method to execute in Unity
$Script:AssetBundleBuildMethod = "AssetBundleScript.BuildAssetBundleForUploadedGLBs" 
$Script:PollingIntervalSeconds = 5 # How often to poll Pub/Sub for new messages
$Script:CompletionTopicPath = "projects/cool-ruler-461702-p8/topics/unity-build-completion-topic"
$Script:GitExePath = "C:\Program Files\Git\bin\git.exe"

# Use $Script: for global variables to ensure they are accessible within functions and the main loop.
# This prevents scope issues when the script is run as a service.


# --- Stop File Setup for Graceful Exit ---
$global:StopFilePath = "$env:TEMP\unity_listener_stop.flag"

$Script:DebugLogs = $false

# Clean up any previous stop file (in case script didn't exit cleanly last time)
if (Test-Path $StopFilePath) {
    Remove-Item $StopFilePath -Force
}

# --- Helper Functions ---

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO" # INFO, WARNING, ERROR
    )
    $timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    # Optional: Log to file as well
    Add-Content -Path $Script:UnityLogFilePath -Value $logEntry
}

function Test-AndCreateFolder {
    param (
        [string]$Path
    )
    if (-not (Test-Path $Path)) {
        Write-Log "Creating folder: $Path"
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        return $true
    }
    return $false
}

function Invoke-GCloudPullMessage {
    param (
        [string]$SubscriptionPath
    )
    try {
        
        if ($DebugLogs) {Write-Log "Pulling message from Pub/Sub subscription: $SubscriptionPath"}
        # --quiet,  --log-http FOR DEBUGGING
        $gcloudCommandString = "gcloud pubsub subscriptions pull `"$SubscriptionPath`" --format=json --limit=1 --auto-ack" 
        if ($DebugLogs) {Write-Log "Executing gcloud command: $gcloudCommandString"} 
        $messagesJson = (powershell.exe -NoProfile -Command $gcloudCommandString | Out-String).Trim()

        if ($DebugLogs) {Write-Log "Raw gcloud output: $messagesJson"} # Log the raw output

        if ($messagesJson -like "*ERROR:*") {
            throw "gcloud command failed: $messagesJson"
        }

        if (-not ($messagesJson -match '^\s*\[\s*\]\s*$') -and -not [string]::IsNullOrWhiteSpace($messagesJson)) {
            return $messagesJson | ConvertFrom-Json
        } else {
            return @() # Return empty array if no messages
        }
    } catch {
        Write-Log "Error pulling Pub/Sub message: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.ScriptPosition)" -Level "ERROR"
        return $null # Indicate failure
    }
}

function Invoke-GCloudPublishMessage {
    param (
        [string]$TopicPath,
        [hashtable]$MessageAttributes,
        [hashtable]$MessagePayload
    )
    try {
        # 1. Convert the PowerShell Hashtable to a JSON string.
        #    -Compress removes unnecessary whitespace, which is good for CLI args.
        $completionMessagePayloadJson = $MessagePayload | ConvertTo-Json -Compress

        # 2. Encode the JSON string to Base64
        #    This converts the JSON text into a safe, ASCII-only string of characters.
        $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($completionMessagePayloadJson)
        $base64EncodedMessage = [System.Convert]::ToBase64String($jsonBytes)

        # --- IMPORTANT: REPLACE THIS WITH YOUR ACTUAL FULL PATH TO GCLOUD.EXE ---
        $gcloudExePath = "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud"
        # --- END OF IMPORTANT REPLACEMENT ---

        # Construct arguments as an array for direct execution.
        # Pass the Base64 encoded string as the message.
        $gcloudArgs = @(
            "pubsub",
            "topics",
            "publish",
            $TopicPath, # TopicPath is a string, PowerShell will quote it if it contains spaces
            "--message=$base64EncodedMessage" # This is the key change!
        )

        # Add attributes (these are simpler key=value pairs, already handled correctly)
        foreach ($key in $MessageAttributes.Keys) {
            $value = $MessageAttributes[$key]
            $gcloudArgs += "--attribute=$key=$value"
        }

        if ($DebugLogs) {Write-Log "Executing gcloud publish command directly (gcloud.exe):"}
        if ($DebugLogs) {Write-Log "gcloud $($gcloudArgs -join ' ')"}

        # Execute the command directly
        # Capture stderr to stdout using 2>&1
        $gcloudOutput = & $gcloudExePath @gcloudArgs 2>&1

        if ($DebugLogs) {Write-Log "gcloud publish output: $($gcloudOutput | Out-String)"}
        if ($DebugLogs) {Write-Log "gcloud exited with code: $LASTEXITCODE"}

        if ($LASTEXITCODE -ne 0) {
            throw "gcloud command failed with exit code: $LASTEXITCODE"
        }
        Write-Log "Build completion message published successfully."
        return $true
    } catch {
        Write-Log "Error publishing build completion message: $($_.Exception.Message)" -Level "ERROR"
        if ($_.Exception.InnerException) {
            Write-Log "Inner exception: $($_.Exception.InnerException.Message)" -Level "ERROR"
        }
        return $false
    }
}


# In your Invoke-GitOperations function, around the commit validation
function Invoke-GitOperations {
    param (
        [string]$BranchName,
        [string]$CommitHash
    )
    Set-Location $UnityProjectPath -ErrorAction Stop

    try {
        Write-Log "DEBUG (GitOps): Starting Git operations for CommitHash: $CommitHash on branch: $BranchName"
        #Write-Log "DEBUG (GitOps): Current working directory: $(Get-Location)"
        #Write-Log "DEBUG (GitOps): Git executable path: $GitExePath"

        # --- Step 1: Fetch all to ensure local knowledge of remote state ---
        if ($DebugLogs) {Write-Log "DEBUG (GitOps): Performing 'git fetch --all'..."}
        $fetchOutputLines = & $GitExePath fetch --all 2>&1
        if ($DebugLogs) {
            Write-Log "DEBUG (GitOps): Raw 'git fetch --all' output (length: $($fetchOutputLines.Count) lines):" # Use .Count for array
            Write-Log "--------------------------------------------------------"
            Write-Log (($fetchOutputLines | Out-String).Trim())
            Write-Log "--------------------------------------------------------"
        }
        if ($LASTEXITCODE -ne 0) { throw "Git fetch --all failed with exit code $LASTEXITCODE." }
        if ($DebugLogs) {Write-Log "INFO (GitOps): Git fetch completed. (No output means no new changes)."}

        # --- Step 2: Check if the requested commit exists locally after the fetch ---
        Write-Log "INFO (GitOps): Verifying requested commit hash '$CommitHash' locally..."
        $catFileResultLines = & $GitExePath cat-file -t $CommitHash 2>&1
        $catFileExitCode = $LASTEXITCODE # Capture exit code immediately

        if ($DebugLogs) {
            Write-Log "DEBUG (GitOps): Raw 'git cat-file -t' output (length: $($catFileResultLines.Count) lines):"
            Write-Log "--------------------------------------------------------"
            Write-Log (($catFileResultLines | Out-String).Trim())
            Write-Log "--------------------------------------------------------"
        }

        if ($catFileExitCode -ne 0 -or (($catFileResultLines | Out-String).Trim() -ne "commit")) {
            # Commit not found or not a 'commit' object locally.
            # This is where we might need to be more aggressive or fail.
            if ($DebugLogs) {Write-Log "WARNING (GitOps): Commit '$CommitHash' not found or is not a commit object locally after fetch. Attempting 'git pull --ff-only' on branch '$BranchName' to bring it in." -Level "WARN"}

            # --- Step 3: If commit isn't local, try to pull the target branch ---
            # Checkout the target branch first to ensure we are on it for the pull
            Write-Log "DEBUG (GitOps): Checking out local branch '$BranchName' for pull attempt..."
            $checkoutBranchOutput = & $GitExePath checkout $BranchName 2>&1
            if ($DebugLogs) {Write-Log (($checkoutBranchOutput | Out-String).Trim())}
            if ($LASTEXITCODE -ne 0) { throw "Failed to checkout branch '$BranchName' before pull: $LASTEXITCODE." }

            # Perform a pull to update the current branch.
            # --ff-only ensures it only fast-forwards, avoiding merge conflicts if script is re-run.
            if ($DebugLogs) {Write-Log "DEBUG (GitOps): Performing 'git pull --ff-only origin $BranchName'..."}
            $pullOutputLines = & $GitExePath pull --ff-only origin $BranchName 2>&1
            if ($DebugLogs) {
                Write-Log "DEBUG (GitOps): Raw 'git pull' output (length: $($pullOutputLines.Count) lines):"
                Write-Log "--------------------------------------------------------"
                Write-Log (($pullOutputLines | Out-String).Trim())
                Write-Log "--------------------------------------------------------"
            }
            if ($LASTEXITCODE -ne 0) { throw "Git pull --ff-only origin $BranchName failed with exit code $LASTEXITCODE. This might mean your local branch '$BranchName' has diverge from origin/$BranchName or the requested commit is not on this branch." }
            if ($DebugLogs) {Write-Log "INFO (GitOps): Git pull completed successfully."}

            # Re-check if the commit exists after the pull
            if ($DebugLogs) {Write-Log "INFO (GitOps): Re-verifying requested commit hash '$CommitHash' after pull..."}
            $catFileResultLines = & $GitExePath cat-file -t $CommitHash 2>&1
            $catFileExitCode = $LASTEXITCODE
            $commitExists = (($catFileResultLines | Out-String).Trim())

            if ($catFileExitCode -ne 0 -or ($commitExists -ne "commit")) {
                throw "Commit '$CommitHash' still not found or is not a commit object after fetch and pull. This indicates a problem with the commit itself or the repository state (e.g., shallow clone, commit not on '$BranchName' remote branch)."
            }
            if ($DebugLogs) {Write-Log "INFO (GitOps): Commit '$CommitHash' verified as a valid commit object after pull."}

        } else {
            Write-Log "INFO (GitOps): Commit '$CommitHash' already exists locally and is a valid commit object."
        }

        # --- Step 4: Checkout the specific commit ---
        if ($DebugLogs) {Write-Log "INFO (GitOps): Checking out specific commit: $CommitHash"}
        $checkoutCommitOutput = & $GitExePath checkout "$CommitHash" 2>&1
        #Write-Log (($checkoutCommitOutput | Out-String).Trim())

        if ($LASTEXITCODE -ne 0) {
            throw "Git checkout $CommitHash failed with exit code $LASTEXITCODE. Ensure the commit is reachable and valid."
        }
        Write-Log "INFO (GitOps): Git operations complete. Repository is now at commit: $CommitHash"
        return $true

    } catch {
        Write-Log "ERROR (GitOps): Git operation failed: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "ERROR (GitOps): Line: $($_.InvocationInfo.ScriptLineNumber), Position: $($_.InvocationInfo.ScriptPosition)" -Level "ERROR"
        return $false
    }
}

function Invoke-UnityBuild {
    param (
        [string]$UnityEditorPath,
        [string]$UnityProjectPath,
        [string]$UnityLogFilePath,
        [string]$BuildMethod,
        [string]$BuildOutputFolder,
        [string]$ExeName = "Google_ADK_Example_Game.exe",
        [string]$session
    )
    $FinalExePath = Join-Path $BuildOutputFolder $ExeName

    $unityCommand = "`"$UnityEditorPath`""
    if ($BuildMethod -eq $Script:GameBuildMethod) {
        $unityArgs = @(
            "-batchmode",
            "-quit",
            "-logFile", "`"$UnityLogFilePath`"",
            "-projectPath", "`"$UnityProjectPath`"",
            "-executeMethod", "$BuildMethod",
            "-buildWindowsPlayer", "`"$FinalExePath`""
        )
    }
    elseif ($BuildMethod -eq $Script:AssetBundleBuildMethod) {
        $unityArgs = @(
        "-batchmode",
        "-quit",
        "-logFile", "`"$UnityLogFilePath`"",
        "-projectPath", "`"$UnityProjectPath`"",
        "-executeMethod", "$BuildMethod",
        "-session", "$session"
        )
    }
    else {
        Write-Log "Unrecognized build command"
        return $false
    }

    Write-Log "Executing Unity command: $unityCommand $($unityArgs -join ' ')"

    $process = Start-Process -FilePath $unityCommand -ArgumentList $unityArgs -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue

    if ($process.ExitCode -eq 0) {
        Write-Log "Unity build completed successfully."
        return $true
    } else {
        Write-Log "Unity build failed with exit code $($process.ExitCode). Check log file: $UnityLogFilePath" -Level "ERROR"
        return $false
    }
}

function Invoke-GCSUpload {
    param (
        [string]$LocalPath,
        [string]$GCSBucket,       
        [string]$GCSObjectPrefix  
    )
    try {
        $gsutilFullPath = "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gsutil.cmd" # <--- YOUR VERIFIED PATH

        # Check if gsutil executable exists at the specified path
        if (-not (Test-Path $gsutilFullPath)) {
            throw "gsutil executable not found at '$gsutilFullPath'. Please verify the path and ensure Cloud SDK is installed correctly."
        }

        if (-not $LocalPath -or -not (Test-Path $LocalPath)) {
            throw "LocalPath '$LocalPath' is invalid or does not exist."
        }
        Write-Log "Preparing to compress: '$LocalPath'"

        # temporary zip file
        $zipFileName = "$(Split-Path -Leaf $LocalPath).zip" # e.g., MyBuild.zip
        $tempZipDir =  "C:\Users\unityadmin\temp"
        if (-not (Test-Path $tempZipDir)) {
            New-Item -Path $tempZipDir -ItemType Directory -Force | Out-Null
        } 
        $tempZipFilePath = Join-Path -Path $tempZipDir -ChildPath $zipFileName

        if ($DebugLogs) {Write-Log "Compressing '$LocalPath' to '$tempZipFilePath'..."}
        Compress-Archive -Path "$LocalPath\*" -DestinationPath $tempZipFilePath -Force
        if (-not (Test-Path $tempZipFilePath)) {
            throw "Failed to create archive at '$tempZipFilePath'"
        }
        if ($DebugLogs) {Write-Log "Compression complete."}

        $GCSObjectPrefix = $GCSObjectPrefix -replace '\\', '/'
        $GCSObjectPrefix = $GCSObjectPrefix.TrimEnd('/')

        $gcsObjectName = "$GCSObjectPrefix/$zipFileName"
        
        $cleanGCSBucket = $GCSBucket -replace '^gs://', '' -replace '/$', '' 

        $fullGcsDestination = "gs://$cleanGCSBucket/$gcsObjectName"
        $fullGcsDestination = $fullGcsDestination -replace '/$', '' # Remove trailing slash

        if ($DebugLogs) {Write-Log "Uploading '$tempZipFilePath' to GCS: '$fullGcsDestination'"}

        # Upload the single zipped file
        $gsutilArgs = @(
            "cp",
            "`"$tempZipFilePath`"",    
            "`"$fullGcsDestination`"" 
        )

        try {
            if ($DebugLogs) {
                Write-Log "Executing gsutil command: '$gsutilFullPath' $($gsutilArgs -join ' ')"
            }

            # Capture all output as string to avoid triggering PowerShell error records
            $gsutilOutput = & "$gsutilFullPath" @gsutilArgs 2>&1 | Out-String

            if ($DebugLogs) {
                Write-Log "gsutil output:`n$gsutilOutput"
                Write-Log "gsutil exited with code: $LASTEXITCODE"
            }

            if ($LASTEXITCODE -ne 0) {
                throw "gsutil upload failed with exit code: $LASTEXITCODE"
            }

            # Clear any lingering error objects to prevent serialization
            $Error.Clear()

            Write-Log "Artifact uploaded to $fullGcsDestination"
            return $true, $fullGcsDestination
        }
        catch {
            Write-Log "[ERROR] gsutil upload failed: $_"
            return $false, $null
        }

    } catch {
        Write-Log "Error during GCS upload process: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.ScriptPosition)" -Level "ERROR"
        return $false, $null
    } finally {
        # Clean up the temporary zip file
        if (Test-Path $tempZipFilePath) {
            Write-Log "Cleaning up temporary zip file: '$tempZipFilePath'"
            Remove-Item $tempZipFilePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Handle-AssetBuildRequest {
    param (
        $message_data
    )

    # Deconstruct message
    $buildId = $message_data.build_id
    $gcsAssetUrl = $message_data.gcs_asset_location_url
    $sessionId = $message_data.session_id
    $timestamp = $message_data.request_timestamp

    Write-Log "Handling asset-build for session: $sessionId"

    # Paths
    $userGlbFolder = Join-Path $Script:UnityProjectPath "UserGlbFiles\$sessionId\assets"
    $userBundleOutputFolder = Join-Path $Script:UnityProjectPath "BuildLLM\UserAssetBundles\$sessionId\assets"
    $finalBundleCopyFolder = Join-Path $Script:UnityProjectPath "BuildLLM\Builds\MyAssetBundles"

    # Clean and create GLB folder
    if (Test-Path $userGlbFolder) {
        Remove-Item -Recurse -Force $userGlbFolder
    }
    New-Item -ItemType Directory -Path $userGlbFolder -Force | Out-Null

    # Download GLB to that folder
    # Attempt download and capture exit code
    Write-Log "Running: gsutil cp `"$gcsAssetUrl`" `"$userGlbFolder`""
    $gsutilResult = & gsutil cp "$gcsAssetUrl" "$userGlbFolder" 2>&1
    Write-Log "gsutil result: $gsutilResult"

    if (-Not (Test-Path $userGlbFolder)) {
        Write-Log "ERROR: File was not downloaded to expected path: $userGlbFolder" -Level "ERROR"
        exit 1
    }

    # Build asset bundle
    $unityEditorPath = $Script:UnityEditorPath
    $unityProjectPath = $Script:UnityProjectPath
    $logPath = Join-Path $unityProjectPath "asset_bundle_log_$sessionId.txt"

    $assetBundleCommand = "`"$unityEditorPath`""
    $assetBundleArgs = @(
        "-batchmode",
        "-quit",
        "-logFile", "`"$logPath`"",
        "-projectPath", "`"$unityProjectPath`"",
        "-executeMethod", "AssetBundleScript.BuildAssetBundleForUploadedGLBs",
        "-session", "$sessionId"
    )

    # Note that for asset build, the build output folder just has the log
    # The asset bundles are put at <UnityProject>/UserAssetBundles/<session_id>/assets
    $assetBundleOutputFolder = Join-Path (Join-Path (Join-Path $unityProjectPath "UserAssetBundles") $sessionId) "assets"
    Write-Log "Asset bundle output folder is $assetBundleOutputFolder"

    $buildOutputFolder = Join-Path $Script:BuildOutputBaseFolder "AssetBuild_$sessionId"
    Write-Log "Trying to make folder at path $buildOutputFolder"

    if (Test-Path $buildOutputFolder) {
        Remove-Item -Path $buildOutputFolder -Recurse -Force
    }
    Test-AndCreateFolder $buildOutputFolder

    # Run Unity headless build
    if (Invoke-UnityBuild -UnityEditorPath $unityEditorPath `
                          -UnityProjectPath $unityProjectPath `
                          -UnityLogFilePath (Join-Path $buildOutputFolder "unity_build_log.txt") `
                          -BuildMethod $Script:AssetBundleBuildMethod `
                          -BuildOutputFolder $buildOutputFolder `
                          -session $sessionId) {
        $buildStatus = "success"
    } else {
        $buildStatus = "unity_build_failed"
    }

    Write-Log "Asset build status: $buildStatus"

    # Upload to GCS if success
    if ($buildStatus -eq "success") {
        $uploadSuccess, $uploadedPath = Invoke-GCSUpload -LocalPath $assetBundleOutputFolder `
                                                -GCSBucket $Script:GCSBucket `
                                                -GCSObjectPrefix "game-builds/assets/$sessionId/"
        if ($uploadSuccess) {
            $finalGcsPath = $uploadedPath
        } else {
            $buildStatus = "upload_failed"
        }
    }

    # Publish completion message
    $completionAttributes = @{}
    $completionPayload = @{
        session_id = $sessionId
        status = $buildStatus
        gcs_path = $finalGcsPath
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
        build_id = $buildId
    }

    Invoke-GCloudPublishMessage -TopicPath $Script:CompletionTopicPath `
                                -MessageAttributes $completionAttributes `
                                -MessagePayload $completionPayload

    Write-Log "Asset build process completed for session $sessionId with status: $buildStatus"
    Write-Log "--------------------------------------------------------"
}

# --- Setup ---

Write-Log "UnityBuildListener Service Started."

try {
    # Attempt to change directory, forcing a terminating error on failure
    Set-Location $UnityProjectPath -ErrorAction Stop
} catch {
    # If Set-Location failed, log the error and exit
    $errorMessage = "FATAL ERROR: Failed to set working directory to '$UnityProjectPath'. Details: $($_.Exception.Message)"
    Write-Log $errorMessage -Level "FATAL"

    # Exit the script with a non-zero exit code to signal failure
    exit 1
}

Test-AndCreateFolder (Split-Path $Script:UnityLogFilePath -Parent)
Test-AndCreateFolder $Script:BuildOutputBaseFolder

Write-Log "Listening to Pub/Sub subscription: $Script:SubscriptionPath"

# --- Main Loop ---

while (-not (Test-Path $StopFilePath)) {
    $messages = Invoke-GCloudPullMessage -SubscriptionPath $Script:SubscriptionPath

    if ($messages -and $messages.Count -gt 0) {
        $message = $messages[0].message
        $decodedBytes = [System.Convert]::FromBase64String($message.data)
        $jsonPayloadString = [System.Text.Encoding]::UTF8.GetString($decodedBytes).Trim()

        Write-Log "Received raw JSON payload string: '$jsonPayloadString'"

        try {
            # Convert the JSON string into a PowerShell object
            $messagePayload = $jsonPayloadString | ConvertFrom-Json
            if ($DebugLogs) {Write-Log "Successfully parsed JSON payload."}
        } catch {
            Write-Log "ERROR: Failed to parse JSON payload. Message: $_" -Level "ERROR"
            # You might want to acknowledge the message and exit this iteration if parsing fails
            # This requires access to the message_id ($msg.ackId) earlier in the loop
            # For now, let's just exit this iteration of the loop
            continue # Skip to the next message or iteration of the while loop
        }
        
        $command = $messagePayload.command # If you still use a top-level command string

        if ($command -eq "asset-build") {
             Set-Location $UNITY_PROJECT_PATH # Ensure we're in the repo directory
            Handle-AssetBuildRequest -message_data $messagePayload
        }
        if ($command -eq "start_build") {

            # Now access fields directly from the $messagePayload object
            $receivedBuildId = $messagePayload.build_id
            $branchName = $messagePayload.branch_name # New field
            $commitHash = $messagePayload.commit_hash # New field
            $isTestBuild = $messagePayload.is_test_build # Accessing the boolean directly

            # Your log messages and conditional checks now use the new variables
            if ($DebugLogs) {
                Write-Log "Processing build_id: $receivedBuildId"
                Write-Log "Received command: '$command'"
                Write-Log "Received branch_name: '$branchName'"
                Write-Log "Received commit_hash: '$commitHash'"
                Write-Log "Is Test Build: $isTestBuild"
            }

            $skipUnityBuild = $isTestBuild

            $buildStatus = "failed"
            $finalGcsPath = ""
            $currentBuildOutputFolder = ""

            if (-not (Test-Path $GitExePath)) {
                $error_msg = "ERROR: Git executable not found at '$GitExePath'. Please verify Git installation. Aborting."
                Write-Log $error_msg -Level "ERROR"
                continue # Skip to the next message
            }
            if ($DebugLogs) {Write-Log "DEBUG: Git executable '$GitExePath' confirmed to exist."}

            Set-Location $UNITY_PROJECT_PATH # Ensure we're in the repo directory
            $currentHeadCommit = ($( & $GitExePath rev-parse HEAD 2>&1) | Out-String).Trim()

            if ($DebugLogs) {Write-Log "Current HEAD commit: $currentHeadCommit"}
            if ($DebugLogs) {Write-Log "Requested commit:    $commitHash"}

            if ($currentHeadCommit -eq $commitHash) {
                Write-Log "Repository is already at the requested commit ($commitHash). Skipping Git operations."
                # Set a flag to skip the full Git operations call
                $skipGitOperations = $true
            } else {
                Write-Log "Repository needs to change commit. Proceeding with Git operations."
                $skipGitOperations = $false
            }

            # --- Git Operations ---
            if (-not $skipGitOperations) {
                if ($DebugLogs) {Write-Log "Performing Git checkout..."}
                if (-not (Test-Path $UnityProjectPath)) {
                    Write-Error "Unity project path '$UnityProjectPath' does not exist."
                    $error_msg = "Unity project path not found."
                    throw $error_msg
                } else {
                    # Call the updated Invoke-GitOperations function
                    # Note: Invoke-GitOperations now directly checks out the commit hash.
                    # The $BranchName parameter is still passed but might not be used
                    # by the function itself if it prioritizes CommitHash.
                    $git_success = Invoke-GitOperations -BranchName $branchName -CommitHash $commitHash
                    if (-not $git_success) {
                        # Invoke-GitOperations already logged the error
                        throw "Git operations failed during checkout."
                    }
                    Write-Log "Git operations complete."
                }
            } # End if -not $skipGitOperations

            # Determine build output folder name
            if ($commitHash) {
                $currentBuildOutputFolder = Join-Path $Script:BuildOutputBaseFolder $commitHash
            } else {
                $currentBuildOutputFolder = Join-Path $Script:BuildOutputBaseFolder "Build_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            }

            if (Test-AndCreateFolder $currentBuildOutputFolder) {
                Write-Log "Created build output folder: $currentBuildOutputFolder"
                if ($skipUnityBuild) {
                    if ($DebugLogs) {Write-Log "Creating dummy file for test mode..."}
                    $dummyFile = Join-Path $currentBuildOutputFolder "DUMMY.txt"
                    "This is a test build placeholder." | Out-File -FilePath $dummyFile -Encoding UTF8
                }
            } else {
                Write-Log "Build output folder already exists: $currentBuildOutputFolder"
            }

            if ($buildStatus -ne "git_failed") { # Only attempt Unity build if Git ops succeeded or not applicable
                if ($skipUnityBuild) {
                    Write-Log "Skipping actual Unity build based on --nobuild flag."
                    $buildStatus = "nobuild"
                } else {
                    Write-Log "Proceeding with actual Unity build..."
                    if (Invoke-UnityBuild -UnityEditorPath $Script:UnityEditorPath `
                                        -UnityProjectPath $Script:UnityProjectPath `
                                        -UnityLogFilePath $Script:UnityLogFilePath `
                                        -BuildMethod $Script:GameBuildMethod `
                                        -BuildOutputFolder $currentBuildOutputFolder `
                                        -session "") {
                        $buildStatus = "success"
                    } else {
                        $buildStatus = "unity_build_failed"
                    }
                }
            }

            # Upload artifacts if the build (or no-build) was processed and a folder was created
            if ($buildStatus -eq "success" -or $buildStatus -eq "nobuild") {
                $uploadSuccess, $uploadedPath = Invoke-GCSUpload -LocalPath $currentBuildOutputFolder `
                                                        -GCSBucket $Script:GCSBucket `
                                                        -GCSObjectPrefix "game-builds/universal/$branchName/$commitHash/"
                if ($uploadSuccess) {
                    $finalGcsPath = $uploadedPath
                } else {
                    $buildStatus = "upload_failed"
                    Write-Log "GCS upload failed." -Level "ERROR"
                }
            } else {
                Write-Log "Skipping GCS upload due to build status: $buildStatus"
            }

            # Publish completion message
            $completionAttributes = @{}
            $completionPayload = @{
                session_id = "placeholder"
                commit = $commitHash
                branch = $branchName
                status = "success"
                is_test_build = $isTestBuild
                gcs_path = $finalGcsPath
                timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
                build_id = $receivedBuildId
            }
            Invoke-GCloudPublishMessage -TopicPath $Script:CompletionTopicPath `
                                        -MessageAttributes $completionAttributes `
                                        -MessagePayload $completionPayload

            Write-Log "--------------------------------------------------------"

        } else {
            Write-Log "Received unrecognized message: '$messageData'" -Level "WARNING"
        }
    } else {
        if ($DebugLogs) {Write-Log "No message received on this pull"}
    }

    Start-Sleep -Seconds $Script:PollingIntervalSeconds
}

Write-Log "Stop file detected at $StopFilePath. Shutting down UnityBuildListener gracefully."
