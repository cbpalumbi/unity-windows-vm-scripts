# UnityBuildListener.ps1
# This script listens for Pub/Sub messages and triggers Unity builds.

# --- Configuration Variables ---
$Script:SubscriptionPath = "projects/cool-ruler-461702-p8/subscriptions/unity-build-subscription"
$Script:GCSBucket = "gs://my_adk_unity_hackathon_builds_2025"
$Script:UnityProjectPath = "C:\UnityProjects\Google_ADK_Example_Game"
$Script:UnityEditorPath = "C:\Program Files\Unity\Hub\Editor\6000.0.50f1\Editor\Unity.exe"
$Script:UnityLogFilePath = "C:\Users\unityadmin\Documents\UnityLogs\unity_build_log.txt"
$Script:BuildOutputBaseFolder = "C:\Users\unityadmin\Documents\UnityBuilds" # Base folder for builds
$Script:BuildMethod = "BuildScript.PerformBuild" # The method to execute in Unity
$Script:PollingIntervalSeconds = 5 # How often to poll Pub/Sub for new messages
$Script:CompletionTopicPath = "projects/cool-ruler-461702-p8/topics/unity-build-completion-topic"

# Use $Script: for global variables to ensure they are accessible within functions and the main loop.
# This prevents scope issues when the script is run as a service.


# --- Stop File Setup for Graceful Exit ---
$global:StopFilePath = "$env:TEMP\unity_listener_stop.flag"

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
        Write-Log "Pulling message from Pub/Sub subscription: $SubscriptionPath"
        # REMOVE --quiet AND ADD --log-http FOR DEBUGGING
        $gcloudCommandString = "gcloud pubsub subscriptions pull `"$SubscriptionPath`" --format=json --limit=1 --auto-ack" # Removed --quiet
        Write-Log "Executing gcloud command: $gcloudCommandString" # Added for visibility
        $messagesJson = (powershell.exe -NoProfile -Command $gcloudCommandString | Out-String).Trim()

        Write-Log "Raw gcloud output: $messagesJson" # Log the raw output

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
        $completionMessagePayloadJson = $MessagePayload | ConvertTo-Json -Compress
        
        # No need to escape internal quotes if we pass it as a direct argument
        # $escapedPayloadForGcloud = $completionMessagePayloadJson.Replace('"', '\"') # This is no longer needed
        # $gcloudMessageArg = "--message=`"$escapedPayloadForGcloud`"" # This changes

        # --- IMPORTANT: REPLACE THIS WITH YOUR ACTUAL FULL PATH TO GCLOUD.EXE ---
        $gcloudExePath = "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud"
        # --- END OF IMPORTANT REPLACEMENT ---

        # Construct arguments as an array for direct execution
        $gcloudArgs = @(
            "pubsub",
            "topics",
            "publish",
            $TopicPath, # TopicPath is a string, PowerShell will quote it if it contains spaces
            "--message=$completionMessagePayloadJson" # Pass the raw JSON string directly to --message
        )

        # Add attributes
        foreach ($key in $MessageAttributes.Keys) {
            $value = $MessageAttributes[$key]
            $gcloudArgs += "--attribute=$key=$value" # PowerShell will handle quoting for these too
        }

        Write-Log "Executing gcloud publish command directly (gcloud.exe):"
        # For logging, join arguments for display
        Write-Log "gcloud $($gcloudArgs -join ' ')"

        # Execute the command directly
        # Capture stderr to stdout using 2>&1
        $gcloudOutput = & $gcloudExePath @gcloudArgs 2>&1

        Write-Log "gcloud publish output: $($gcloudOutput | Out-String)"
        Write-Log "gcloud exited with code: $LASTEXITCODE"

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

function Invoke-GitOperations {
    param (
        [string]$ProjectPath,
        [string]$GitReference
    )
    Set-Location $ProjectPath
    try {
        Write-Log "Fetching latest changes..."
        #powershell.exe -NoProfile -Command "git fetch --all" | Out-String | Write-Log
        Write-Log ((powershell.exe -NoProfile -Command "git fetch --all") | Out-String)

        Write-Log "Checking out Git reference: $GitReference"
        #powershell.exe -NoProfile -Command "git checkout `"$GitReference`"" | Out-String | Write-Log
        Write-Log ((powershell.exe -NoProfile -Command "git checkout `"$GitReference`"") | Out-String)

        Write-Log "Pulling latest changes for $GitReference..."
        #powershell.exe -NoProfile -Command "git pull origin `"$GitReference`"" | Out-String | Write-Log
        Write-Log ((powershell.exe -NoProfile -Command "git pull origin `"$GitReference`"") | Out-String)

        Write-Log "Git operations complete."
        return $true
    } catch {
        Write-Log "Git operation failed: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.ScriptPosition)" -Level "ERROR"
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
        [string]$ExeName = "Google_ADK_Example_Game.exe"
    )
    $FinalExePath = Join-Path $BuildOutputFolder $ExeName

    if (-not (Test-AndCreateFolder $BuildOutputFolder)) {
        Write-Log "Build output folder already exists: $BuildOutputFolder"
    }

    $unityCommand = "`"$UnityEditorPath`""
    $unityArgs = @(
        "-batchmode",
        "-quit",
        "-logFile", "`"$UnityLogFilePath`"",
        "-projectPath", "`"$UnityProjectPath`"",
        "-executeMethod", "$BuildMethod",
        "-buildWindowsPlayer", "`"$FinalExePath`""
    )

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
        $finalGcsPath = "$GCSBucket/$GCSObjectPrefix"
        Write-Log "Uploading '$LocalPath' to GCS: '$finalGcsPath'"

        # Upload directory content
        $gsutilCommandStringDir = "gsutil cp -r `"$LocalPath\*`" `"$finalGcsPath`""
        #powershell.exe -NoProfile -Command $gsutilCommandStringDir | Out-String | Write-Log
        Write-Log ((powershell.exe -NoProfile -Command $gsutilCommandStringDir) | Out-String)


        # Upload specific log file if it's outside the directory
        if ($LocalPath -ne $Script:UnityLogFilePath) { # Avoid double upload if log is inside
            $gsutilLogCommandString = "gsutil cp `"$Script:UnityLogFilePath`" `"$finalGcsPath`""
            #powershell.exe -NoProfile -Command $gsutilLogCommandString | Out-String | Write-Log
            Write-Log ((powershell.exe -NoProfile -Command $gsutilLogCommandString) | Out-String)

        }

        Write-Log "Artifacts uploaded to $finalGcsPath"
        return $true, $finalGcsPath
    } catch {
        Write-Log "Error uploading to GCS: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.ScriptPosition)" -Level "ERROR"
        return $false, $null
    }
}

# --- Main Loop ---
# This conditional block ensures the main loop only runs when the script is executed directly,
# not when it's dot-sourced (e.g., by Pester for testing).
if (-not (Get-Module -ListAvailable -Name Pester)) {

    Test-AndCreateFolder (Split-Path $Script:UnityLogFilePath -Parent)
    Test-AndCreateFolder $Script:BuildOutputBaseFolder

    Write-Log "UnityBuildListener Service Started."
    Write-Log "Listening to Pub/Sub subscription: $Script:SubscriptionPath"

    while (-not (Test-Path $StopFilePath)) {
        $messages = Invoke-GCloudPullMessage -SubscriptionPath $Script:SubscriptionPath

        if ($messages -and $messages.Count -gt 0) {
            $message = $messages[0].message
            $decodedBytes = [System.Convert]::FromBase64String($message.data)
            $messageData = [System.Text.Encoding]::UTF8.GetString($decodedBytes).Trim()
            Write-Log "Received message data: '$messageData'"

            $receivedBuildId = $message.attributes.build_id
            if (-not $receivedBuildId) {
                Write-Log "No build_id found in message attributes. Generating a new one." -Level "WARNING"
                $receivedBuildId = "unknown_build_" + (Get-Date -Format 'yyyyMMdd_HHmmss')
            }
            Write-Log "Processing build_id: $receivedBuildId"

            $skipUnityBuild = ($message.attributes.nobuild -eq "true")
            if ($skipUnityBuild) {
                Write-Log "NOTE: 'nobuild' flag is 'true'. Unity build will be skipped."
            }

            $buildStatus = "failed"
            $finalGcsPath = ""
            $currentBuildOutputFolder = ""
            $gitRef = $null # Initialize gitRef

            if ($messageData -eq "start_build_for_unityadmin" -or $messageData -like "checkout_and_build:*") {
                if ($messageData -like "checkout_and_build:*") {
                    $gitRef = $messageData.Split(":")[1]
                    Write-Log "Request to checkout Git ref '$gitRef' and build."
                    if (-not (Invoke-GitOperations -ProjectPath $Script:UnityProjectPath -GitReference $gitRef)) {
                        $buildStatus = "git_failed"
                        Write-Log "Git operations failed. Not attempting Unity build." -Level "ERROR"
                    } else {
                        Write-Log "Git operations successful."
                    }
                } else {
                    Write-Log "Triggering standard Unity build (no specific Git ref)."
                }

                # Determine build output folder name
                if ($gitRef) {
                    $currentBuildOutputFolder = Join-Path $Script:BuildOutputBaseFolder "Build_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$($gitRef -replace '[^a-zA-Z0-9_.-]', '_')"
                } else {
                    $currentBuildOutputFolder = Join-Path $Script:BuildOutputBaseFolder "Build_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
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
                                            -BuildMethod $Script:BuildMethod `
                                            -BuildOutputFolder $currentBuildOutputFolder) {
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
                                                            -GCSObjectPrefix "builds/$receivedBuildId/"
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
                $completionAttributes = @{
                    build_id = $receivedBuildId
                    status = $buildStatus
                    # Add session_id if you extract it from the incoming message
                    # For now, it's a placeholder
                    session_id = "placeholder"
                }
                $completionPayload = @{
                    message = "Build completed for $receivedBuildId"
                    gcs_path = $finalGcsPath
                    timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
                }
                Invoke-GCloudPublishMessage -TopicPath $Script:CompletionTopicPath `
                                            -MessageAttributes $completionAttributes `
                                            -MessagePayload $completionPayload

            } else {
                Write-Log "Received unrecognized message: '$messageData'" -Level "WARNING"
            }
        } else {
            Write-Log "No message received on this pull"
        }

        Start-Sleep -Seconds $Script:PollingIntervalSeconds
    }

    Write-Log "Stop file detected at $StopFilePath. Shutting down UnityBuildListener gracefully."

}