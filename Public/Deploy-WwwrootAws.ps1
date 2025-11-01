<#
.SYNOPSIS
    Deploys a wwwroot folder directly to AWS S3
.DESCRIPTION
    Deploys the contents of a local wwwroot folder directly to an S3 bucket without
    building or publishing a project. This is useful for deploying pre-built static
    web content, manually prepared files, or for development/testing scenarios.

    All content is deployed under the wwwroot/ prefix in S3. If the wwwroot folder
    contains subfolders, each subfolder is deployed to s3://{bucket}/wwwroot/{subfolder}/.
    If no subfolders exist, files are deployed to s3://{bucket}/wwwroot/.
.PARAMETER WwwrootFolder
    The path to the wwwroot folder to deploy (relative to current directory).
    Defaults to "./wwwroot"
.PARAMETER AppName
    The application name used to construct the S3 bucket name.
    If not specified, reads from apppublish.json in the current or parent directory.
.EXAMPLE
    Deploy-WwwrootAws
    Deploys ./wwwroot folder using AppName from apppublish.json
    If wwwroot contains subfolders (e.g., en-US, es-MX), each is deployed separately
.EXAMPLE
    Deploy-WwwrootAws -WwwrootFolder "./dist/wwwroot"
    Deploys a custom wwwroot folder location
.EXAMPLE
    Deploy-WwwrootAws -AppName "MyApp" -WwwrootFolder "./build/output"
    Deploys custom folder with explicit AppName (no apppublish.json needed)
.NOTES
    - Does not build or publish any projects
    - Creates S3 bucket if it doesn't exist
    - Uses --delete flag to sync (removes files not in local folder)
    - Automatically detects and deploys subfolders separately
    - Requires valid AWS credentials and appropriate permissions
.OUTPUTS
    Boolean - Returns $true on success, $false on failure
#>
function Deploy-WwwrootAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$WwwrootFolder = "./wwwroot",

        [Parameter(Mandatory=$false)]
        [string]$AppName
    )

    try {
        Write-LzAwsVerbose "Starting wwwroot deployment"

        # Load system configuration
        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Account = $script:Account
        $Config = $script:Config
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        # Validate wwwroot folder exists
        Write-LzAwsVerbose "Validating wwwroot folder: $WwwrootFolder"
        $ResolvedPath = Resolve-Path -Path $WwwrootFolder -ErrorAction SilentlyContinue
        if ($null -eq $ResolvedPath -or -not (Test-Path $ResolvedPath -PathType Container)) {
            $errorMessage = @"
Error: wwwroot folder not found
Function: Deploy-WwwrootAws
Hints:
  - Check if the folder exists at: $WwwrootFolder
  - Verify the path is correct (relative to current directory)
  - Ensure the folder contains the files you want to deploy
"@
            throw $errorMessage
        }

        $LocalFolderPath = $ResolvedPath.Path
        Write-LzAwsVerbose "Using folder: $LocalFolderPath"

        # Resolve AppName - use parameter if provided, otherwise look for apppublish.json
        if ([string]::IsNullOrWhiteSpace($AppName)) {
            Write-LzAwsVerbose "AppName not provided, searching for apppublish.json"

            # Try current directory first, then parent
            $AppPublishPath = $null
            if (Test-Path "./apppublish.json") {
                $AppPublishPath = "./apppublish.json"
            } elseif (Test-Path "../apppublish.json") {
                $AppPublishPath = "../apppublish.json"
            }

            if ($null -eq $AppPublishPath) {
                $errorMessage = @"
Error: AppName not specified and apppublish.json not found
Function: Deploy-WwwrootAws
Hints:
  - Provide the -AppName parameter explicitly, or
  - Create an apppublish.json file in the current or parent directory
  - apppublish.json should contain: { "AppName": "your-app-name" }
"@
                throw $errorMessage
            }

            Write-LzAwsVerbose "Found apppublish.json at: $AppPublishPath"
            try {
                $AppPublish = Get-Content -Path $AppPublishPath -Raw | ConvertFrom-Json
                if ($null -eq $AppPublish.AppName -or [string]::IsNullOrWhiteSpace($AppPublish.AppName)) {
                    $errorMessage = @"
Error: Invalid apppublish.json format
Function: Deploy-WwwrootAws
Hints:
  - Check if AppName is defined in apppublish.json
  - Verify the JSON format is valid
  - Ensure AppName has a non-empty value
"@
                    throw $errorMessage
                }
                $AppName = $AppPublish.AppName
            }
            catch {
                $errorMessage = @"
Error: Failed to parse apppublish.json
Function: Deploy-WwwrootAws
Hints:
  - Verify the JSON file is valid
  - Check for syntax errors in the file
  - Ensure the file is readable
Error Details: $($_.Exception.Message)
"@
                throw $errorMessage
            }
        }

        Write-LzAwsVerbose "Using AppName: $AppName"

        # Create S3 bucket
        $BucketName = "$SystemKey---webapp-$AppName-$SystemSuffix"
        Write-LzAwsVerbose "Creating S3 bucket: $BucketName"
        New-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -BucketType "WEBAPP" -ProfileName $ProfileName

        # Check for subfolders
        $Subfolders = Get-ChildItem -Directory -Path $LocalFolderPath -ErrorAction SilentlyContinue

        if ($null -eq $Subfolders -or $Subfolders.Count -eq 0) {
            # No subfolders - deploy the wwwroot folder contents under wwwroot/ prefix
            Write-LzAwsVerbose "No subfolders found, deploying wwwroot folder contents"
            $S3KeyPrefix = "wwwroot"
            $SyncCommand = "aws s3 sync `"$LocalFolderPath`" `"s3://$BucketName/$S3KeyPrefix`" --delete --region $Region --profile `"$ProfileName`""
            Write-LzAwsVerbose "Running sync command: $SyncCommand"

            $SyncResult = Invoke-Expression $SyncCommand 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                $errorMessage = @"
Error: Failed to sync files to S3
Function: Deploy-WwwrootAws
Hints:
  - Check if you have permission to write to the S3 bucket
  - Verify the local files exist and are accessible
  - Ensure AWS credentials are valid
Error Details: Sync operation failed with exit code $exitCode
Command Output: $($SyncResult | Out-String)
"@
                throw $errorMessage
            }

            Write-Host "Successfully deployed wwwroot to S3" -ForegroundColor Green
            Write-Host "Bucket: $BucketName" -ForegroundColor Cyan
            Write-Host "Prefix: $S3KeyPrefix" -ForegroundColor Cyan
        }
        else {
            # Deploy each subfolder separately under wwwroot/ prefix
            Write-LzAwsVerbose "Found $($Subfolders.Count) subfolders, deploying each under wwwroot/ prefix"

            foreach ($Subfolder in $Subfolders) {
                $SubfolderName = $Subfolder.Name
                Write-Host "Deploying subfolder: $SubfolderName" -ForegroundColor Yellow
                Write-LzAwsVerbose "Processing subfolder: $SubfolderName"

                $S3KeyPrefix = "wwwroot/$SubfolderName"
                $SyncCommand = "aws s3 sync `"$($Subfolder.FullName)`" `"s3://$BucketName/$S3KeyPrefix`" --delete --region $Region --profile `"$ProfileName`""
                Write-LzAwsVerbose "Running sync command: $SyncCommand"

                $SyncResult = Invoke-Expression $SyncCommand 2>&1
                $exitCode = $LASTEXITCODE
                if ($exitCode -ne 0) {
                    $errorMessage = @"
Error: Failed to sync subfolder '$SubfolderName' to S3
Function: Deploy-WwwrootAws
Hints:
  - Check if you have permission to write to the S3 bucket
  - Verify the local files exist and are accessible
  - Ensure AWS credentials are valid
Error Details: Sync operation failed with exit code $exitCode
Command Output: $($SyncResult | Out-String)
"@
                    throw $errorMessage
                }

                Write-Host "Successfully deployed subfolder: $SubfolderName to wwwroot/$SubfolderName" -ForegroundColor Green
            }

            Write-Host "Successfully deployed all $($Subfolders.Count) subfolders to S3" -ForegroundColor Green
            Write-Host "Bucket: $BucketName" -ForegroundColor Cyan
            Write-Host "Prefix: wwwroot/" -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
