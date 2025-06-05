# UnityBuildListener.ps1
# This script listens for Pub/Sub messages and triggers Unity builds.

# --- Configuration Variables ---
$SubscriptionPath = "projects/cool-ruler-461702-p8/subscriptions/unity-build-subscription"
$GCSBucket = "gs://my_adk_unity_hackathon_builds_2025" 
$UnityProjectPath = "C:\UnityProjects\Google_ADK_Example_Game"
$UnityEditorPath = "C:\Program Files\Unity\Hub\Editor\6000.0.50f1\Editor\Unity.exe"
$UnityLogFilePath = "C:\Users\unityadmin\Documents\UnityLogs\unity_build_log.txt"
$BuildOutputBaseFolder = "C:\Users\unityadmin\Documents\UnityBuilds" # Base folder for builds
$BuildMethod = "BuildScript.PerformBuild" # The method to execute in Unity
$PollingIntervalSeconds = 5 # How often to poll Pub/Sub for new messages

# --- Pub/Sub Topic for Build Completions ---
$CompletionTopicPath = "projects/cool-ruler-461702-p8/topics/unity-build-completion-topic"

# --- Ensure Log and Build Output Folders Exist ---
$LogFolder = Split-Path $UnityLogFilePath -Parent
if (-not (Test-Path $LogFolder)) {
    Write-Host "Creating log folder: $LogFolder"
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}
if (-not (Test-Path $BuildOutputBaseFolder)) {
    Write-Host "Creating build output base folder: $BuildOutputBaseFolder"
    New-Item -ItemType Directory -Path $BuildOutputBaseFolder -Force | Out-Null
}

Write-Host "UnityBuildListener Service Started."
Write-Host "Listening to Pub/Sub subscription: $SubscriptionPath"

while ($true) {
    # Attempt to pull a message from Pub/Sub
    try {
        # Construct the gcloud command as a single string, exactly as it would be typed
        # We need to include --format=json to get attributes like build_id
        $gcloudCommandString = "gcloud pubsub subscriptions pull `"$SubscriptionPath`" --format=json --limit=1 --auto-ack --quiet" # use --log-http for cleaner output

        # Execute this command string using powershell.exe, and capture its output into $messagesJson
        $messagesJson = powershell.exe -NoProfile -Command $gcloudCommandString | Out-String

        # Trim the result of Out-String immediately after capturing it
        $messagesJson = $messagesJson.Trim()

        # Check if the output contains "ERROR:" which indicates a gcloud failure
        if ($messagesJson -like "*ERROR:*") {
            throw "gcloud command failed: $messagesJson"
        }
    } catch {
        Write-Error "Error pulling Pub/Sub message: $($_.Exception.Message)"
        Write-Error "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.ScriptPosition)" # Add line number for debugging
        Start-Sleep -Seconds $PollingIntervalSeconds
        continue
    }

    # If $messagesJson is empty or just whitespace after Trim(), ConvertFrom-Json will error.
    # We need to handle cases where no message was pulled successfully.
    if (-not ($messagesJson -match '^\s*\[\s*\]\s*$') -and -not [string]::IsNullOrWhiteSpace($messagesJson)) {
        # Only attempt to convert if it looks like actual JSON data (not empty array or just whitespace)
        try {
            $messages = $messagesJson | ConvertFrom-Json
        } catch {
            Write-Error "Failed to parse JSON from gcloud output: $($_.Exception.Message)"
            Write-Error "Raw gcloud output: $messagesJson"
            Start-Sleep -Seconds $PollingIntervalSeconds
            continue
        }
    } else {
        # No messages or empty JSON array, continue to next poll cycle
        $messages = @() # Ensure $messages is an empty array if no messages were pulled
        # Write-Host "No messages received. Waiting..." # Uncomment for more verbose 'no message' logging
    }

    if ($messages -and $messages.Count -gt 0) {
        $message = $messages[0].message # Get the actual message object
        $decodedBytes = [System.Convert]::FromBase64String($message.data)
        $messageData = [System.Text.Encoding]::UTF8.GetString($decodedBytes).Trim()
        Write-Host "Received message: '$messageData'"

        # --- Extract build_id from message attributes ---
        $receivedBuildId = $message.attributes.build_id
        if ($receivedBuildId) {
            Write-Host "Extracted build_id from attributes: $receivedBuildId"
        } else {
            Write-Host "No build_id found in message attributes."
            # Assign a placeholder if no build_id is found (e.g., for legacy messages)
            $receivedBuildId = "unknown_build_" + (Get-Date -Format 'yyyyMMdd_HHmmss')
        }

        # --- Check for 'nobuild' flag from message attributes ---
        # Initialize the flag to false by default
        $skipUnityBuild = $false
        $nobuildAttributeValue = $message.attributes.nobuild

        if ($nobuildAttributeValue) {
            Write-Host "Extracted 'nobuild' attribute from attributes: '$nobuildAttributeValue'"
            if ($nobuildAttributeValue -eq "true") {
                $skipUnityBuild = $true
                Write-Host "NOTE: 'nobuild' flag is 'true'. Unity build will be skipped."
            } else {
                Write-Host "NOTE: 'nobuild' attribute found but its value ('$nobuildAttributeValue') is not 'true'. Proceeding with build."
            }
        } else {
            Write-Host "No 'nobuild' attribute found in message attributes. Proceeding with build."
        }

        # --- Initialize variables for completion message ---
        $buildStatus = "failed" # Assume failure unless successful
        $finalGcsPath = ""
        $currentBuildOutputFolder = "" # To store the specific build folder for the current operation

        # --- Message Processing Logic ---
        if ($messageData -eq "start_build_for_unityadmin" -or $messageData -like "checkout_and_build:*") {
            if ($skipUnityBuild) {
                Write-Host "Skipping actual Unity build based on --nobuild flag."
                $buildStatus = "nobuild"
                
            } else {
                Write-Host "Proceeding with actual Unity build..."
                $gitRef = $null
                if ($messageData -like "checkout_and_build:*") {
                    $gitRef = $messageData.Split(":")[1]
                    Write-Host "Received request to checkout Git ref '$gitRef' and build."
                    Set-Location $UnityProjectPath
                    try {
                        Write-Host "Fetching latest changes..."
                        powershell.exe -NoProfile -Command "git fetch --all" | Out-String | Write-Host
                        Write-Host "Checking out Git reference: $gitRef"
                        powershell.exe -NoProfile -Command "git checkout `"$gitRef`"" | Out-String | Write-Host
                        Write-Host "Pulling latest changes for $gitRef..."
                        powershell.exe -NoProfile -Command "git pull origin `"$gitRef`"" | Out-String | Write-Host
                        Write-Host "Git operations complete. Now triggering build for '$gitRef'."
                    } catch {
                        Write-Error "Git operation failed: $($_.Exception.Message)"
                        Write-Error "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.ScriptPosition)"
                        # Don't exit, try to proceed to Unity build, but ensure status reflects failure
                        $buildStatus = "git_failed"
                    }
                    $currentBuildOutputFolder = Join-Path $BuildOutputBaseFolder "Build_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$($gitRef -replace '[^a-zA-Z0-9_.-]', '_')"
                } else { # For "start_build_for_unityadmin"
                    Write-Host "Triggering standard Unity build..."
                    $currentBuildOutputFolder = Join-Path $BuildOutputBaseFolder "Build_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                }

                $FinalExePath = Join-Path $currentBuildOutputFolder "Google_ADK_Example_Game.exe"

                # Create the specific build output folder
                if (-not (Test-Path $currentBuildOutputFolder)) {
                    New-Item -ItemType Directory -Path $currentBuildOutputFolder -Force | Out-Null
                    Write-Host "Created build output folder: $currentBuildOutputFolder"
                }

                # --- Construct and Execute Unity Build Command ---
                $unityCommand = "`"$UnityEditorPath`"" # Enclose path in quotes
                $unityArgs = @(
                    "-batchmode",
                    "-quit",
                    "-logFile", "`"$UnityLogFilePath`"",
                    "-projectPath", "`"$UnityProjectPath`"",
                    "-executeMethod", "$BuildMethod",
                    "-buildWindowsPlayer", "`"$FinalExePath`"" # Enclose path in quotes
                )

                Write-Host "Executing Unity command: $unityCommand $($unityArgs -join ' ')"

                $process = Start-Process -FilePath $unityCommand -ArgumentList $unityArgs -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue

                if ($process.ExitCode -eq 0) {
                    Write-Host "Unity build completed successfully."
                    $buildStatus = "success" # Update status

                    # --- Upload Output Files to GCS ---
                    Write-Host "Uploading build artifacts to GCS..."
                    $gcsObjectPrefix = "builds/$receivedBuildId/" # Use build_id for GCS path
                    $finalGcsPath = "$GCSBucket/$gcsObjectPrefix" # Store this for completion message

                    try {
                        $gsutilCommandString = "gsutil cp -r `"$currentBuildOutputFolder\*`" `"$finalGcsPath`""
                        powershell.exe -NoProfile -Command $gsutilCommandString | Out-String | Write-Host

                        $gsutilLogCommandString = "gsutil cp `"$UnityLogFilePath`" `"$finalGcsPath`""
                        powershell.exe -NoProfile -Command $gsutilLogCommandString | Out-String | Write-Host

                        Write-Host "Artifacts uploaded to $finalGcsPath"
                        Write-Host "Unity build log uploaded."
                    } catch {
                        Write-Error "Error uploading to GCS: $($_.Exception.Message)"
                        Write-Error "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.ScriptPosition)"
                        $buildStatus = "upload_failed" # Update status for upload failure
                    }
                } else {
                    Write-Error "Unity build failed with exit code $($process.ExitCode). Check log file: $UnityLogFilePath"
                    # $buildStatus is already "failed" by default
                }
            }

            # --- Publish Build Completion Message ---
            Write-Host "Publishing build completion message for build_id: $receivedBuildId with status: $buildStatus"

            $completionMessagePayload = @{
                build_id = $receivedBuildId
                status = $buildStatus
                gcs_path = $finalGcsPath # Will be empty string if upload failed
                timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') # ISO 8601 format
            } | ConvertTo-Json -Compress

            $receivedSessionId = "placeholder"

            try {
                # Define the arguments for gcloud pubsub topics publish as an array
                $gcloudArgs = @(
                    "pubsub",
                    "topics",
                    "publish",
                    $CompletionTopicPath, # No need for explicit quotes here, PowerShell handles it
                    "--message=$completionMessagePayload", # PowerShell will handle quoting for the JSON string
                    "--attribute=build_id=$receivedBuildId",
                    "--attribute=session_id=$receivedSessionId",
                    "--attribute=status=$buildStatus"
                )

                Write-Host "Executing gcloud command: gcloud $($gcloudArgs -join ' ')" # For debugging

                # Execute gcloud directly. Output will go to stdout/stderr.
                gcloud @gcloudArgs

                # Check the $LASTEXITCODE variable for success/failure
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Build completion message published successfully."
                } else {
                    Write-Error "gcloud command failed with exit code: $LASTEXITCODE"
                }

            } catch {
                Write-Error "Error publishing build completion message: $($_.Exception.Message)"
                # Also output specific error details if available
                if ($_.Exception.InnerException) {
                    Write-Error "Inner exception: $($_.Exception.InnerException.Message)"
                }
            }

        } else {
            Write-Host "Received unrecognized message: '$messageData'"
        }
    } else {
        # Write-Host "No messages received. Waiting..."
    }

    Start-Sleep -Seconds $PollingIntervalSeconds
}