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

        $SystemConfig = Get-SystemConfig
        # Get-SystemConfig already handles exit 1 on failure

        $Region = $SystemConfig.Region
        $Account = $SystemConfig.Account      
        $ProfileName = $SystemConfig.Config.Profile
        $SystemKey = $SystemConfig.Config.SystemKey
        $SystemSuffix = $SystemConfig.Config.SystemSuffix

        # Verify apppublish.json exists and is valid
        $AppPublishPath = "./$ProjectFolder/apppublish.json"
        if (-not (Test-Path $AppPublishPath)) {
            Write-Host "Error: apppublish.json not found"
            Write-Host "Hints:"
            Write-Host "  - Check if apppublish.json exists in: $AppPublishPath"
            Write-Host "  - Verify the project folder is correct"
            Write-Host "  - Ensure the configuration file is present"
            exit 1
        }

        try {
            $AppPublish = Get-Content -Path $AppPublishPath -Raw | ConvertFrom-Json
            if ($null -eq $AppPublish.AppName) {
                Write-Host "Error: Invalid apppublish.json format"
                Write-Host "Hints:"
                Write-Host "  - Check if AppName is defined in apppublish.json"
                Write-Host "  - Verify the JSON format is valid"
                Write-Host "  - Ensure all required fields are present"
                exit 1
            }
        }
        catch {
            Write-Host "Error: Failed to parse apppublish.json"
            Write-Host "Hints:"
            Write-Host "  - Check if the JSON syntax is valid"
            Write-Host "  - Verify the file is not corrupted"
            Write-Host "  - Ensure the file is properly formatted"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        $AppName = $AppPublish.AppName
        $BucketName = "$SystemKey---webapp-$AppName-$SystemSuffix"

        Write-LzAwsVerbose "Checking S3 bucket: $BucketName"
        try {
            $BucketExists = Get-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -ProfileName $ProfileName
            if (-not $BucketExists) {
                Write-Host "Error: S3 bucket not found"
                Write-Host "Hints:"
                Write-Host "  - Check if the bucket exists in AWS S3 console"
                Write-Host "  - Verify the bucket name is correct"
                Write-Host "  - Ensure you have permission to access the bucket"
                exit 1
            }
        }
        catch {
            Write-Host "Error: Failed to check S3 bucket"
            Write-Host "Hints:"
            Write-Host "  - Check if you have permission to access S3"
            Write-Host "  - Verify AWS credentials are valid"
            Write-Host "  - Ensure the region is correct"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Create local assets directory if it doesn't exist
        $LocalAssetsPath = Join-Path $ProjectFolder "wwwroot\assets"
        if (-not (Test-Path $LocalAssetsPath)) {
            Write-LzAwsVerbose "Creating local assets directory: $LocalAssetsPath"
            try {
                New-Item -ItemType Directory -Path $LocalAssetsPath -Force | Out-Null
            }
            catch {
                Write-Host "Error: Failed to create local assets directory"
                Write-Host "Hints:"
                Write-Host "  - Check if you have permission to create directories"
                Write-Host "  - Verify the path is valid and accessible"
                Write-Host "  - Ensure there is enough disk space"
                Write-Host "Error Details: $($_.Exception.Message)"
                exit 1
            }
        }

        # Sync assets from S3 to local directory
        $S3KeyPrefix = "wwwroot/assets"
        $SyncCommand = "aws s3 sync `"s3://$BucketName/$S3KeyPrefix`" `"$LocalAssetsPath`" --profile `"$ProfileName`""
        Write-LzAwsVerbose "Running sync command: $SyncCommand"

        try {
            $SyncResult = Invoke-Expression $SyncCommand 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Sync operation failed with exit code $LASTEXITCODE. Error: $SyncResult"
            }
            Write-Host "Successfully retrieved assets" -ForegroundColor Green
        }
        catch {
            Write-Host "Error: Failed to sync assets from S3"
            Write-Host "Hints:"
            Write-Host "  - Check if you have permission to read from the S3 bucket"
            Write-Host "  - Verify the local directory is writable"
            Write-Host "  - Ensure AWS credentials are valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
    }
    catch {
        Write-Host "Error: An unexpected error occurred while retrieving assets"
        Write-Host "Hints:"
        Write-Host "  - Check the AWS S3 console for bucket status"
        Write-Host "  - Verify all required AWS services are available"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
} 