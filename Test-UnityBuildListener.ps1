# UnityBuildListener.Tests.ps1
# Pester unit tests for UnityBuildListener.ps1

# Wrap everything in a top-level Describe block
Describe "UnityBuildListener Script" {

    BeforeAll {
        # Dot-source the script to make its functions available in the test session.
        # This ensures that functions like Write-Log, Test-AndCreateFolder, etc., are loaded.
        # We do this in BeforeAll so it's loaded once for all tests.
        . "$PSScriptRoot\UnityBuildListener.ps1"
    }

    BeforeEach {
        # Reset mocks before each test to ensure test isolation
        # And clean up global variables if they are set in the script itself.
        Remove-Variable -Name Script -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name global -Scope Global -ErrorAction SilentlyContinue
        # Re-initialize script variables for each test run to ensure a clean state
        # A more robust way might be to have a separate config for tests or pass them as parameters.
        # For now, we'll re-dot source or define minimal necessary config.
        . "$PSScriptRoot\UnityBuildListener.ps1" # Re-source to reset $Script: variables

        # Define a temporary log file path for tests to avoid conflicts
        $Script:UnityLogFilePath = Join-Path $env:TEMP "unity_build_log_test_$(Get-Random).txt"
        if (Test-Path $Script:UnityLogFilePath) { Remove-Item $Script:UnityLogFilePath }

        # Clean up any stop file created by previous tests or script execution
        $global:StopFilePath = Join-Path $env:TEMP "unity_listener_stop_test_$(Get-Random).flag"
        if (Test-Path $global:StopFilePath) { Remove-Item $global:StopFilePath -Force }

        # Mock external commands and cmdlets that have side effects or external dependencies
        Mock 'Write-Host' {} # Suppress console output during tests
        Mock 'Add-Content' {} # Suppress file logging during tests, unless testing logging itself
        Mock 'Test-Path' { return $false } # Default to path not existing, override in specific tests
        Mock 'New-Item' { param([string]$Path); New-Object PSObject | Add-Member -MemberType NoteProperty -Name FullName -Value $Path -PassThru } # Simulate New-Item
        Mock 'Remove-Item' {}
        Mock 'Set-Location' {}
        Mock 'Get-Date' { return [DateTime]::Parse("2025-06-06 18:00:00") } # Consistent date for tests
        Mock 'Start-Sleep' {} # Don't sleep during tests
        Mock 'powershell.exe' { throw "powershell.exe was called unexpectedly. Mock it!" } # Catch unmocked calls
        Mock 'Start-Process' {
            param (
                [string]$FilePath,
                [array]$ArgumentList,
                [switch]$NoNewWindow,
                [switch]$Wait,
                [switch]$PassThru,
                [switch]$ErrorAction
            )
            # Simulate a successful process by default
            $MockProcess = New-Object PSObject
            $MockProcess | Add-Member -MemberType NoteProperty -Name ExitCode -Value 0
            $MockProcess | Add-Member -MemberType NoteProperty -Name Path -Value $FilePath
            $MockProcess | Add-Member -MemberType NoteProperty -Name Arguments -Value ($ArgumentList -join ' ')
            return $MockProcess
        }
    }

    AfterEach {
        # Clean up the test log file
        if (Test-Path $Script:UnityLogFilePath) { Remove-Item $Script:UnityLogFilePath -ErrorAction SilentlyContinue }
        # Clean up the test stop file
        if (Test-Path $global:StopFilePath) { Remove-Item $global:StopFilePath -ErrorAction SilentlyContinue }
    }

    AfterAll {
        # Undefine functions sourced from the script to avoid pollution for other test runs or sessions.
        # This is important if you run multiple Pester test files in the same session.
        Get-Command -Module (Get-Module -Name Pester -ErrorAction SilentlyContinue) | Where-Object { $_.Name -like '*-*' } | ForEach-Object {
            if ($_.CommandType -eq 'Function' -and $_.ScriptBlock -ne $null) {
                # Check if the function originated from our script by looking at its definition
                # This is a bit tricky, but a general cleanup is often sufficient.
                # No specific undefine needed here, as Pester isolates mocks per test.
            }
        }
    }


    Describe "Write-Log" {
        It "logs an INFO message to host and file" {
            Mock 'Add-Content' {
                param([string]$Path, [string]$Value)
                $script:LoggedContent = $Value # Capture content for assertion
                $script:LoggedPath = $Path # Capture path for assertion
            }
            Write-Log -Message "Test Info Message" -Level "INFO"

            $script:LoggedContent | Should -Match "\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[INFO\] Test Info Message"
            $script:LoggedPath | Should -Be $Script:UnityLogFilePath
            # If you were mocking Write-Host, you could check that too.
        }

        It "logs an ERROR message to host and file" {
            Mock 'Add-Content' { $script:LoggedContent = $args[1] }
            Write-Log -Message "Test Error Message" -Level "ERROR"
            $script:LoggedContent | Should -Match "\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[ERROR\] Test Error Message"
        }
    }

    Describe "Test-AndCreateFolder" {
        It "creates a folder if it does not exist" {
            Mock 'Test-Path' { return $false } # Simulate folder not existing
            Mock 'New-Item' {
                param([string]$Path, [string]$ItemType, [switch]$Force)
                $script:NewItemCalled = $true
                $script:NewItemPath = $Path
                return New-Object PSObject | Add-Member -MemberType NoteProperty -Name FullName -Value $Path -PassThru
            }
            $result = Test-AndCreateFolder -Path "C:\NonExistentFolder"
            $result | Should -Be $true
            $script:NewItemCalled | Should -Be $true
            $script:NewItemPath | Should -Be "C:\NonExistentFolder"
        }

        It "does not create a folder if it already exists" {
            Mock 'Test-Path' { return $true } # Simulate folder existing
            Mock 'New-Item' { $script:NewItemCalled = $true } # This mock should NOT be called
            $result = Test-AndCreateFolder -Path "C:\ExistingFolder"
            $result | Should -Be $false
            $script:NewItemCalled | Should -Be $null # Should not be set
        }
    }

    Describe "Invoke-GCloudPullMessage" {
        It "successfully pulls and parses a message" {
            $mockGcloudOutput = @'
[
  {
    "ackId": "projects/cool-ruler-461702-p8/subscriptions/unity-build-subscription/messages/12345",
    "message": {
      "attributes": {
        "build_id": "test-build-123",
        "some_other_attr": "value"
      },
      "data": "c3RhcnRfYnVpbGRfZm9yX3VuaXR5YWRtaW4=",
      "messageId": "12345",
      "publishTime": "2025-06-06T18:00:00Z"
    }
  }
]
'@
            Mock 'powershell.exe' {
                param($NoProfile, $Command)
                $Command | Should -Match "gcloud pubsub subscriptions pull"
                $Command | Should -Match "--format=json --limit=1 --auto-ack"
                return $mockGcloudOutput
            }

            $messages = Invoke-GCloudPullMessage -SubscriptionPath "projects/test/subscriptions/test-sub"
            $messages | Should -Not -BeNullOrEmpty
            $messages.Count | Should -Be 1
            $messages[0].message.attributes.build_id | Should -Be "test-build-123"
            $messages[0].message.data | Should -Be "c3RhcnRfYnVpbGRfZm9yX3VuaXR5YWRtaW4="
        }

        It "returns empty array if no messages are pulled" {
            Mock 'powershell.exe' { return "[]" } # Simulate empty array output
            $messages = Invoke-GCloudPullMessage -SubscriptionPath "projects/test/subscriptions/test-sub"
            $messages | Should -BeEmpty
        }

        It "returns empty array if gcloud output is whitespace" {
            Mock 'powershell.exe' { return "   " } # Simulate whitespace output
            $messages = Invoke-GCloudPullMessage -SubscriptionPath "projects/test/subscriptions/test-sub"
            $messages | Should -BeEmpty
        }

        It "handles gcloud command failure" {
            Mock 'powershell.exe' {
                return "ERROR: (gcloud.event.subscriptions.pull) Some error occurred."
            }
            Mock 'Write-Log' { $script:LogError = $args[0]; $script:LogLevel = $args[1] } # Capture log
            $messages = Invoke-GCloudPullMessage -SubscriptionPath "projects/test/subscriptions/test-sub"
            $messages | Should -BeNull # Should return null on failure
            $script:LogError | Should -Match "Error pulling Pub/Sub message: gcloud command failed"
            $script:LogLevel | Should -Be "ERROR"
        }

        It "handles JSON parsing error" {
            Mock 'powershell.exe' { return "{invalid json" }
            Mock 'Write-Log' { $script:LogError = $args[0]; $script:LogLevel = $args[1] }
            $messages = Invoke-GCloudPullMessage -SubscriptionPath "projects/test/subscriptions/test-sub"
            $messages | Should -BeNull
            $script:LogError | Should -Match "Error pulling Pub/Sub message: ConvertFrom-Json"
            $script:LogLevel | Should -Be "ERROR"
        }
    }

    Describe "Invoke-GCloudPublishMessage" {
        BeforeEach {
            $Script:gcloudExePath = "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.exe"
        }

        It "successfully publishes a message with payload and attributes" {
            $testTopic = "projects/test/topics/completion"
            $testAttributes = @{ status = "success"; build_id = "abc-123" }
            $testPayload = @{ message = "Build complete"; gcs_path = "gs://path"; timestamp = "2025-06-06T18:00:00Z" }

            Mock 'Start-Process' {
                param (
                    [string]$FilePath,
                    [array]$ArgumentList,
                    [switch]$NoNewWindow,
                    [switch]$Wait,
                    [switch]$PassThru,
                    [switch]$ErrorAction
                )
                $FilePath | Should -Be $Script:gcloudExePath
                $ArgumentList[0] | Should -Be "pubsub"
                $ArgumentList[1] | Should -Be "topics"
                $ArgumentList[2] | Should -Be "publish"
                $ArgumentList[3] | Should -Be $testTopic
                $ArgumentList | Should -ContainMatch "--message=*" # Check for message argument
                $ArgumentList | Should -ContainMatch "--attribute=status=success"
                $ArgumentList | Should -ContainMatch "--attribute=build_id=abc-123"

                # Simulate successful exit code
                $MockProcess = New-Object PSObject
                $MockProcess | Add-Member -MemberType NoteProperty -Name ExitCode -Value 0
                return $MockProcess
            }
            $result = Invoke-GCloudPublishMessage -TopicPath $testTopic -MessageAttributes $testAttributes -MessagePayload $testPayload
            $result | Should -Be $true
        }

        It "returns false on gcloud command failure" {
            $testTopic = "projects/test/topics/completion"
            $testAttributes = @{ status = "failed" }
            $testPayload = @{ message = "Build failed" }

            Mock 'Start-Process' {
                param (
                    [string]$FilePath,
                    [array]$ArgumentList,
                    [switch]$NoNewWindow,
                    [switch]$Wait,
                    [switch]$PassThru,
                    [switch]$ErrorAction
                )
                # Simulate failed exit code
                $MockProcess = New-Object PSObject
                $MockProcess | Add-Member -MemberType NoteProperty -Name ExitCode -Value 1
                return $MockProcess
            }
            Mock 'Write-Log' { $script:LogError = $args[0]; $script:LogLevel = $args[1] }

            $result = Invoke-GCloudPublishMessage -TopicPath $testTopic -MessageAttributes $testAttributes -MessagePayload $testPayload
            $result | Should -Be $false
            $script:LogError | Should -Match "Error publishing build completion message: gcloud command failed with exit code: 1"
            $script:LogLevel | Should -Be "ERROR"
        }
    }

    Describe "Invoke-GitOperations" {
        It "successfully performs git fetch, checkout, and pull" {
            $script:GitCommandsExecuted = @()
            Mock 'powershell.exe' {
                param($NoProfile, $Command)
                $script:GitCommandsExecuted += $Command
                return "Git command output" # Simulate success
            }
            Mock 'Set-Location' { $script:LocationSet = $args[0] }

            $result = Invoke-GitOperations -ProjectPath "C:\MyUnityProject" -GitReference "main"

            $result | Should -Be $true
            $script:LocationSet | Should -Be "C:\MyUnityProject"
            $script:GitCommandsExecuted | Should -Contain "git fetch --all"
            $script:GitCommandsExecuted | Should -Contain "git checkout `"main`""
            $script:GitCommandsExecuted | Should -Contain "git pull origin `"main`""
        }

        It "returns false on git command failure" {
            Mock 'powershell.exe' {
                param($NoProfile, $Command)
                if ($Command -like "*checkout*") {
                    throw "Git checkout failed"
                }
                return "Success"
            }
            Mock 'Write-Log' { $script:LogError = $args[0]; $script:LogLevel = $args[1] }

            $result = Invoke-GitOperations -ProjectPath "C:\MyUnityProject" -GitReference "bad_branch"
            $result | Should -Be $false
            $script:LogError | Should -Match "Git operation failed: Git checkout failed"
            $script:LogLevel | Should -Be "ERROR"
        }
    }

    Describe "Invoke-UnityBuild" {
        It "successfully invokes Unity build" {
            $mockUnityEditorPath = "C:\Unity\Editor\Unity.exe"
            $mockProjectPath = "C:\UnityProjects\Game"
            $mockLogPath = "C:\Logs\unity.log"
            $mockBuildMethod = "MyBuildScript.DoBuild"
            $mockOutputFolder = "C:\Builds\Game_v1"
            $mockExeName = "Game.exe"

            Mock 'Test-AndCreateFolder' { return $true } # Assume folder is created or exists
            Mock 'Start-Process' {
                param (
                    [string]$FilePath,
                    [array]$ArgumentList,
                    [switch]$NoNewWindow,
                    [switch]$Wait,
                    [switch]$PassThru,
                    [switch]$ErrorAction
                )
                $FilePath | Should -Be "`"$mockUnityEditorPath`"" # Should be quoted
                $ArgumentList | Should -Contain "-batchmode"
                $ArgumentList | Should -Contain "-quit"
                $ArgumentList | Should -Contain "-logFile"
                $ArgumentList | Should -Contain "`"$mockLogPath`""
                $ArgumentList | Should -Contain "-projectPath"
                $ArgumentList | Should -Contain "`"$mockProjectPath`""
                $ArgumentList | Should -Contain "-executeMethod"
                $ArgumentList | Should -Contain $mockBuildMethod
                $ArgumentList | Should -Contain "-buildWindowsPlayer"
                $ArgumentList | Should -Contain "`"C:\Builds\Game_v1\Game.exe`""

                $MockProcess = New-Object PSObject
                $MockProcess | Add-Member -MemberType NoteProperty -Name ExitCode -Value 0
                return $MockProcess
            }

            $result = Invoke-UnityBuild -UnityEditorPath $mockUnityEditorPath `
                                         -UnityProjectPath $mockProjectPath `
                                         -UnityLogFilePath $mockLogPath `
                                         -BuildMethod $mockBuildMethod `
                                         -BuildOutputFolder $mockOutputFolder `
                                         -ExeName $mockExeName
            $result | Should -Be $true
        }

        It "returns false on Unity build failure" {
            $mockUnityEditorPath = "C:\Unity\Editor\Unity.exe"
            $mockProjectPath = "C:\UnityProjects\Game"
            $mockLogPath = "C:\Logs\unity.log"
            $mockBuildMethod = "MyBuildScript.DoBuild"
            $mockOutputFolder = "C:\Builds\Game_v1"

            Mock 'Test-AndCreateFolder' { return $true }
            Mock 'Start-Process' {
                $MockProcess = New-Object PSObject
                $MockProcess | Add-Member -MemberType NoteProperty -Name ExitCode -Value 1 # Simulate failure
                return $MockProcess
            }
            Mock 'Write-Log' { $script:LogError = $args[0]; $script:LogLevel = $args[1] }

            $result = Invoke-UnityBuild -UnityEditorPath $mockUnityEditorPath `
                                         -UnityProjectPath $mockProjectPath `
                                         -UnityLogFilePath $mockLogPath `
                                         -BuildMethod $mockBuildMethod `
                                         -BuildOutputFolder $mockOutputFolder
            $result | Should -Be $false
            $script:LogError | Should -Match "Unity build failed with exit code 1"
            $script:LogLevel | Should -Be "ERROR"
        }
    }

    Describe "Invoke-GCSUpload" {
        BeforeEach {
            $Script:UnityLogFilePath = "C:\Users\unityadmin\Documents\UnityLogs\unity_build_log.txt" # Reset for this test specifically
            Mock 'Write-Log' {} # Suppress logging during checks
        }

        It "successfully uploads directory and log file" {
            $mockLocalPath = "C:\LocalBuilds\MyGame"
            $mockGCSBucket = "gs://my-bucket"
            $mockGCSObjectPrefix = "builds/test-id/"
            $script:GsutilCommandsExecuted = @()

            Mock 'powershell.exe' {
                param($NoProfile, $Command)
                $script:GsutilCommandsExecuted += $Command
                return "Upload successful"
            }

            $result, $uploadedPath = Invoke-GCSUpload -LocalPath $mockLocalPath `
                                                    -GCSBucket $mockGCSBucket `
                                                    -GCSObjectPrefix $mockGCSObjectPrefix

            $result | Should -Be $true
            $uploadedPath | Should -Be "$mockGCSBucket/$mockGCSObjectPrefix"
            $script:GsutilCommandsExecuted | Should -ContainMatch "gsutil cp -r `"$mockLocalPath\*`" `"$mockGCSBucket/$mockGCSObjectPrefix`""
            $script:GsutilCommandsExecuted | Should -ContainMatch "gsutil cp `"$Script:UnityLogFilePath`" `"$mockGCSBucket/$mockGCSObjectPrefix`""
        }

        It "does not upload log file if LocalPath is UnityLogFilePath" {
            $mockLocalPath = $Script:UnityLogFilePath # Simulate local path being the log file
            $mockGCSBucket = "gs://my-bucket"
            $mockGCSObjectPrefix = "logs/test-id/"
            $script:GsutilCommandsExecuted = @()

            Mock 'powershell.exe' {
                param($NoProfile, $Command)
                $script:GsutilCommandsExecuted += $Command
                return "Upload successful"
            }

            $result, $uploadedPath = Invoke-GCSUpload -LocalPath $mockLocalPath `
                                                    -GCSBucket $mockGCSBucket `
                                                    -GCSObjectPrefix $mockGCSObjectPrefix

            $result | Should -Be $true
            $uploadedPath | Should -Be "$mockGCSBucket/$mockGCSObjectPrefix"
            $script:GsutilCommandsExecuted | Should -ContainMatch "gsutil cp -r `"$mockLocalPath\*`" `"$mockGCSBucket/$mockGCSObjectPrefix`""
            # Assert that the second 'gsutil cp' for the log file was NOT called
            $script:GsutilCommandsExecuted | Should -Not -ContainMatch "gsutil cp `"$Script:UnityLogFilePath`" `"$mockGCSBucket/$mockGCSObjectPrefix`"" # This check should fail if it was called
        }

        It "returns false on GCS upload failure" {
            $mockLocalPath = "C:\LocalBuilds\MyGame"
            $mockGCSBucket = "gs://my-bucket"
            $mockGCSObjectPrefix = "builds/test-id/"

            Mock 'powershell.exe' {
                throw "gsutil failed"
            }
            Mock 'Write-Log' { $script:LogError = $args[0]; $script:LogLevel = $args[1] }

            $result, $uploadedPath = Invoke-GCSUpload -LocalPath $mockLocalPath `
                                                    -GCSBucket $mockGCSBucket `
                                                    -GCSObjectPrefix $mockGCSObjectPrefix
            $result | Should -Be $false
            $uploadedPath | Should -Be $null
            $script:LogError | Should -Match "Error uploading to GCS: gsutil failed"
            $script:LogLevel | Should -Be "ERROR"
        }
    }

    Describe "Main Listener Loop" {
        # Testing the main loop is more like an integration test, but we can still mock its dependencies.
        # The challenge is controlling the loop's execution and exit condition.
        # We'll use the $global:StopFilePath for this.

        It "processes a build message and exits when stop file is present" {
            $Script:PollingIntervalSeconds = 0 # Don't wait during test

            # Mock the initial folder creation
            Mock 'Test-AndCreateFolder' { return $true }

            # --- Mock Invoke-GCloudPullMessage to return one message, then empty ---
            $pullCount = 0
            Mock 'Invoke-GCloudPullMessage' {
                $pullCount++
                if ($pullCount -eq 1) {
                    # Simulate a "checkout_and_build" message
                    $mockMessage = @{
                        message = @{
                            attributes = @{ build_id = "test-loop-build-1"; nobuild = "false" };
                            data = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("checkout_and_build:feature/test"));
                        }
                    }
                    return @($mockMessage | ConvertTo-Json | ConvertFrom-Json)
                } else {
                    # Create the stop file after the first pull to exit the loop
                    New-Item -Path $global:StopFilePath -ItemType File -Force | Out-Null
                    return @() # No more messages
                }
            }

            # --- Mock dependent functions to simulate success and capture calls ---
            Mock 'Invoke-GitOperations' {
                param($ProjectPath, $GitReference)
                $script:GitOperationsCalled = $true
                $script:GitRefUsed = $GitReference
                return $true # Simulate success
            }
            Mock 'Invoke-UnityBuild' {
                param($UnityEditorPath, $UnityProjectPath, $UnityLogFilePath, $BuildMethod, $BuildOutputFolder, $ExeName)
                $script:UnityBuildCalled = $true
                $script:UnityBuildOutputFolder = $BuildOutputFolder
                return $true # Simulate success
            }
            Mock 'Invoke-GCSUpload' {
                param($LocalPath, $GCSBucket, $GCSObjectPrefix)
                $script:GCSUploadCalled = $true
                $script:GCSUploadedLocalPath = $LocalPath
                return $true, "$GCSBucket/$GCSObjectPrefix" # Simulate success
            }
            Mock 'Invoke-GCloudPublishMessage' {
                param($TopicPath, $MessageAttributes, $MessagePayload)
                $script:PublishCalled = $true
                $script:PublishedStatus = $MessageAttributes.status
                $script:PublishedGCSPath = $MessagePayload.gcs_path
                return $true # Simulate success
            }

            # Execute the main script block.
            # This is where we run the actual loop.
            # We need to contain the loop execution to prevent infinite loops in tests.
            # This is typically done by creating the stop file within a mock or by letting the test run for a short duration
            # and then asserting that it would have stopped. For this case, modifying Invoke-GCloudPullMessage to create the stop file
            # after one successful pull is a good pattern for controlled loop exit.
            . "$PSScriptRoot\UnityBuildListener.ps1"

            # Assertions
            $script:GitOperationsCalled | Should -Be $true
            $script:GitRefUsed | Should -Be "feature/test"
            $script:UnityBuildCalled | Should -Be $true
            $script:GCSUploadCalled | Should -Be $true
            $script:PublishCalled | Should -Be $true
            $script:PublishedStatus | Should -Be "success"
            $script:PublishedGCSPath | Should -Not -BeNullOrEmpty
            $script:UnityBuildOutputFolder | Should -Match "Build_\d{8}_\d{6}_feature_test" # Verify folder naming
            (Test-Path $global:StopFilePath) | Should -Be $false # Stop file should be cleaned up by the script itself
        }

        It "processes a nobuild message and exits when stop file is present" {
            $Script:PollingIntervalSeconds = 0 # Don't wait during test

            # Mock the initial folder creation
            Mock 'Test-AndCreateFolder' { return $true }

            # --- Mock Invoke-GCloudPullMessage to return one message, then empty ---
            $pullCount = 0
            Mock 'Invoke-GCloudPullMessage' {
                $pullCount++
                if ($pullCount -eq 1) {
                    # Simulate a "nobuild" message
                    $mockMessage = @{
                        message = @{
                            attributes = @{ build_id = "test-nobuild-1"; nobuild = "true" };
                            data = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("start_build_for_unityadmin"));
                        }
                    }
                    return @($mockMessage | ConvertTo-Json | ConvertFrom-Json)
                } else {
                    # Create the stop file after the first pull to exit the loop
                    New-Item -Path $global:StopFilePath -ItemType File -Force | Out-Null
                    return @() # No more messages
                }
            }

            # --- Mock dependent functions to simulate success and capture calls ---
            Mock 'Invoke-GitOperations' {
                $script:GitOperationsCalled = $true
                return $true
            }
            Mock 'Invoke-UnityBuild' {
                $script:UnityBuildCalled = $true
                return $true
            }
            Mock 'Invoke-GCSUpload' {
                param($LocalPath, $GCSBucket, $GCSObjectPrefix)
                $script:GCSUploadCalled = $true
                $script:GCSUploadedLocalPath = $LocalPath
                return $true, "$GCSBucket/$GCSObjectPrefix"
            }
            Mock 'Invoke-GCloudPublishMessage' {
                param($TopicPath, $MessageAttributes, $MessagePayload)
                $script:PublishCalled = $true
                $script:PublishedStatus = $MessageAttributes.status
                return $true
            }

            # Execute the main script block.
            . "$PSScriptRoot\UnityBuildListener.ps1"

            # Assertions for nobuild scenario
            $script:GitOperationsCalled | Should -Be $null # Git ops should NOT be called directly for nobuild
            $script:UnityBuildCalled | Should -Be $null # Unity build should NOT be called
            $script:GCSUploadCalled | Should -Be $true # Upload should still happen
            $script:PublishCalled | Should -Be $true
            $script:PublishedStatus | Should -Be "nobuild" # Status should reflect nobuild
            (Test-Path $global:StopFilePath) | Should -Be $false
        }

        It "handles an empty pull and continues looping until stop file is present" {
            $Script:PollingIntervalSeconds = 0 # Don't wait during test

            # Mock the initial folder creation
            Mock 'Test-AndCreateFolder' { return $true }

            $pullCount = 0
            Mock 'Invoke-GCloudPullMessage' {
                $pullCount++
                if ($pullCount -lt 3) { # Simulate two empty pulls
                    return @()
                } else {
                    # Create the stop file on the third pull to exit the loop
                    New-Item -Path $global:StopFilePath -ItemType File -Force | Out-Null
                    return @()
                }
            }

            Mock 'Invoke-GitOperations' { Fail "GitOperations should not be called" }
            Mock 'Invoke-UnityBuild' { Fail "UnityBuild should not be called" }
            Mock 'Invoke-GCSUpload' { Fail "GCSUpload should not be called" }
            Mock 'Invoke-GCloudPublishMessage' { Fail "GCloudPublish should not be called" }

            $script:LogMessages = @()
            Mock 'Write-Log' { $script:LogMessages += $args[0] } # Capture logs

            # Execute the main script block.
            . "$PSScriptRoot\UnityBuildListener.ps1"

            # Assertions
            $pullCount | Should -Be 3 # Should have pulled 3 times before stopping
            $script:LogMessages | Should -Contain "No message received on this pull" | Should -HaveCount 2 # Two empty pull messages
            $script:LogMessages | Should -Contain "Stop file detected at $global:StopFilePath. Shutting down UnityBuildListener gracefully."
            (Test-Path $global:StopFilePath) | Should -Be $false
        }

        It "handles message with no build_id and generates one" {
            $Script:PollingIntervalSeconds = 0 # Don't wait during test

            Mock 'Test-AndCreateFolder' { return $true }
            Mock 'Invoke-GCloudPullMessage' {
                # Simulate a message with no build_id attribute
                $mockMessage = @{
                    message = @{
                        attributes = @{}; # No build_id
                        data = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("start_build_for_unityadmin"));
                    }
                }
                # Create stop file immediately after returning this message
                New-Item -Path $global:StopFilePath -ItemType File -Force | Out-Null
                return @($mockMessage | ConvertTo-Json | ConvertFrom-Json)
            }

            Mock 'Invoke-GitOperations' { return $true }
            Mock 'Invoke-UnityBuild' { return $true }
            Mock 'Invoke-GCSUpload' {
                param($LocalPath, $GCSBucket, $GCSObjectPrefix)
                $script:GCSUploadedPrefix = $GCSObjectPrefix
                return $true, "$GCSBucket/$GCSObjectPrefix"
            }
            Mock 'Invoke-GCloudPublishMessage' {
                param($TopicPath, $MessageAttributes, $MessagePayload)
                $script:PublishedBuildId = $MessageAttributes.build_id
                $script:PublishedStatus = $MessageAttributes.status
                return $true
            }
            $script:LogMessages = @()
            Mock 'Write-Log' { $script:LogMessages += $args[0] }

            . "$PSScriptRoot\UnityBuildListener.ps1"

            # Assertions
            $script:PublishedBuildId | Should -Match "unknown_build_\d{8}_\d{6}" # Should generate unknown_build_...
            $script:PublishedStatus | Should -Be "success"
            $script:GCSUploadedPrefix | Should -Match "builds/unknown_build_\d{8}_\d{6}/"
            $script:LogMessages | Should -Contain "No build_id found in message attributes. Generating a new one."
        }

        It "handles Git operation failure correctly" {
            $Script:PollingIntervalSeconds = 0

            Mock 'Test-AndCreateFolder' { return $true }
            Mock 'Invoke-GCloudPullMessage' {
                $mockMessage = @{
                    message = @{
                        attributes = @{ build_id = "git-fail-test" };
                        data = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("checkout_and_build:fail-branch"));
                    }
                }
                New-Item -Path $global:StopFilePath -ItemType File -Force | Out-Null
                return @($mockMessage | ConvertTo-Json | ConvertFrom-Json)
            }

            Mock 'Invoke-GitOperations' { return $false } # Simulate Git failure
            Mock 'Invoke-UnityBuild' { Fail "UnityBuild should not be called after Git failure" }
            Mock 'Invoke-GCSUpload' { Fail "GCSUpload should not be called after Git failure leading to build failure" }
            Mock 'Invoke-GCloudPublishMessage' {
                param($TopicPath, $MessageAttributes, $MessagePayload)
                $script:PublishedStatus = $MessageAttributes.status
                $script:PublishedGCSPath = $MessagePayload.gcs_path
                return $true
            }
            $script:LogMessages = @()
            Mock 'Write-Log' { $script:LogMessages += $args[0] }

            . "$PSScriptRoot\UnityBuildListener.ps1"

            $script:PublishedStatus | Should -Be "git_failed"
            $script:PublishedGCSPath | Should -Be "" # No GCS path on Git failure
            $script:LogMessages | Should -Contain "Git operations failed. Not attempting Unity build."
            $script:LogMessages | Should -Contain "Skipping GCS upload due to build status: git_failed"
        }

        It "handles Unity build failure correctly" {
            $Script:PollingIntervalSeconds = 0

            Mock 'Test-AndCreateFolder' { return $true }
            Mock 'Invoke-GCloudPullMessage' {
                $mockMessage = @{
                    message = @{
                        attributes = @{ build_id = "unity-fail-test" };
                        data = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("start_build_for_unityadmin"));
                    }
                }
                New-Item -Path $global:StopFilePath -ItemType File -Force | Out-Null
                return @($mockMessage | ConvertTo-Json | ConvertFrom-Json)
            }

            Mock 'Invoke-GitOperations' { return $true } # Git succeeds
            Mock 'Invoke-UnityBuild' { return $false } # Simulate Unity failure
            Mock 'Invoke-GCSUpload' { Fail "GCSUpload should not be called after Unity build failure" }
            Mock 'Invoke-GCloudPublishMessage' {
                param($TopicPath, $MessageAttributes, $MessagePayload)
                $script:PublishedStatus = $MessageAttributes.status
                $script:PublishedGCSPath = $MessagePayload.gcs_path
                return $true
            }
            $script:LogMessages = @()
            Mock 'Write-Log' { $script:LogMessages += $args[0] }

            . "$PSScriptRoot\UnityBuildListener.ps1"

            $script:PublishedStatus | Should -Be "unity_build_failed"
            $script:PublishedGCSPath | Should -Be "" # No GCS path on Unity build failure
            $script:LogMessages | Should -Contain "Skipping GCS upload due to build status: unity_build_failed"
        }

        It "handles GCS upload failure correctly" {
            $Script:PollingIntervalSeconds = 0

            Mock 'Test-AndCreateFolder' { return $true }
            Mock 'Invoke-GCloudPullMessage' {
                $mockMessage = @{
                    message = @{
                        attributes = @{ build_id = "upload-fail-test" };
                        data = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("start_build_for_unityadmin"));
                    }
                }
                New-Item -Path $global:StopFilePath -ItemType File -Force | Out-Null
                return @($mockMessage | ConvertTo-Json | ConvertFrom-Json)
            }

            Mock 'Invoke-GitOperations' { return $true }
            Mock 'Invoke-UnityBuild' { return $true } # Unity build succeeds
            Mock 'Invoke-GCSUpload' { return $false, $null } # Simulate GCS upload failure
            Mock 'Invoke-GCloudPublishMessage' {
                param($TopicPath, $MessageAttributes, $MessagePayload)
                $script:PublishedStatus = $MessageAttributes.status
                $script:PublishedGCSPath = $MessagePayload.gcs_path
                return $true
            }
            $script:LogMessages = @()
            Mock 'Write-Log' { $script:LogMessages += $args[0] }

            . "$PSScriptRoot\UnityBuildListener.ps1"

            $script:PublishedStatus | Should -Be "upload_failed"
            $script:PublishedGCSPath | Should -Be "" # No GCS path on upload failure
            $script:LogMessages | Should -Contain "GCS upload failed."
        }
    }
} # End of top-level Describe block