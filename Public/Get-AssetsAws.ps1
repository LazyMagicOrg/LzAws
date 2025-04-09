function Get-AssetsAws {
    <#
    .SYNOPSIS
        Retrieves assets from AWS S3 buckets.

    .DESCRIPTION
        Gets assets from specified AWS S3 buckets based on provided filters and parameters.
        Supports retrieving multiple types of assets and filtering by prefix, tags, or other metadata.

    .PARAMETER BucketName
        The name of the S3 bucket to retrieve assets from.

    .PARAMETER Prefix
        Optional prefix to filter S3 objects.

    .PARAMETER Filter
        Optional hashtable of tags or metadata to filter assets.

    .EXAMPLE
        Get-AssetsAws -BucketName "my-assets-bucket"
        Returns all assets from the specified bucket.

    .EXAMPLE
        Get-AssetsAws -BucketName "my-assets-bucket" -Prefix "images/"
        Returns all assets from the images/ prefix in the specified bucket.

    .NOTES
        Requires AWS.Tools.S3 module and appropriate AWS credentials.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProjectFolder = "WASMApp"
    )

    try {
        Write-LzAwsVerbose "Starting assets retrieval"

        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Account = $script:Account  
        $Config = $script:Config    
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        # Verify apppublish.json exists and is valid
        $AppPublishPath = "./$ProjectFolder/apppublish.json"
        if (-not (Test-Path $AppPublishPath)) {
            $errorMessage = @"
Error: apppublish.json not found
Function: Get-AssetsAws
Hints:
  - Check if apppublish.json exists in: $AppPublishPath
  - Verify the project folder is correct
  - Ensure the configuration file is present
"@
            throw $errorMessage
        }

        try {
            $AppPublish = Get-Content -Path $AppPublishPath -Raw | ConvertFrom-Json
        }
        catch {
            $errorMessage = @"
Error: Failed to parse apppublish.json
Function: Get-AssetsAws
Hints:
  - Check if the JSON syntax is valid
  - Verify the file is not corrupted
  - Ensure the file is properly formatted
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        if ($null -eq $AppPublish.AppName) {
            $errorMessage = @"
Error: Invalid apppublish.json format
Function: Get-AssetsAws
Hints:
  - Check if AppName is defined in apppublish.json
  - Verify the JSON format is valid
  - Ensure all required fields are present
"@
            throw $errorMessage
        }

        $AppName = $AppPublish.AppName
        $BucketName = "$SystemKey---webapp-$AppName-$SystemSuffix"

        Write-LzAwsVerbose "Checking S3 bucket: $BucketName"
        $BucketExists = Get-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -ProfileName $ProfileName
        if (-not $BucketExists) {
            $errorMessage = @"
Error: S3 bucket not found
Function: Get-AssetsAws
Hints:
  - Check if the bucket exists in AWS S3 console
  - Verify the bucket name is correct
  - Ensure you have permission to access the bucket
"@
            throw $errorMessage
        }
        

        # Create local assets directory if it doesn't exist
        $LocalAssetsPath = Join-Path $ProjectFolder "wwwroot\assets"
        if (-not (Test-Path $LocalAssetsPath)) {
            Write-LzAwsVerbose "Creating local assets directory: $LocalAssetsPath"
            try {
                New-Item -ItemType Directory -Path $LocalAssetsPath -Force | Out-Null
            }
            catch {
                $errorMessage = @"
Error: Failed to create local assets directory
Function: Get-AssetsAws
Hints:
  - Check if you have permission to create directories
  - Verify the path is valid and accessible
  - Ensure there is enough disk space
Error Details: $($_.Exception.Message)
"@
                throw $errorMessage
            }
        }

        # Sync assets from S3 to local directory
        $S3KeyPrefix = "wwwroot/assets"
        $SyncCommand = "aws s3 sync `"s3://$BucketName/$S3KeyPrefix`" `"$LocalAssetsPath`" --region $Region --profile `"$ProfileName`""
        Write-LzAwsVerbose "Running sync command: $SyncCommand"

        $SyncResult = Invoke-Expression $SyncCommand 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $errorMessage = @"
Error: Failed to sync assets from S3
Function: Get-AssetsAws
Hints:
  - Check if you have permission to read from the S3 bucket
  - Verify the local directory is writable
  - Ensure AWS credentials are valid
Error Details: Sync operation failed with exit code $exitCode
Command Output: $($SyncResult | Out-String)
"@
            throw $errorMessage
        }
        Write-Host "Successfully retrieved assets" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
} 