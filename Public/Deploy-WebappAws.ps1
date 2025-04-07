<#
.SYNOPSIS
    Deploys a web application to AWS infrastructure
.DESCRIPTION
    Deploys a specified web application to AWS, handling all necessary AWS resources
    and configurations including S3, CloudFront, and related services.
.PARAMETER ProjectFolder
    The folder containing the web application project (defaults to "WASMApp")
.PARAMETER ProjectName
    The name of the web application project (defaults to "WASMApp")
.EXAMPLE
    Deploy-WebappAws
    Deploys the web application using default project folder and name
.EXAMPLE
    Deploy-WebappAws -ProjectFolder "MyApp" -ProjectName "MyWebApp"
    Deploys the web application from the specified project
.NOTES
    Requires valid AWS credentials and appropriate permissions
    Must be run in the webapp Solution root folder
.OUTPUTS
    None
#>
function Get-PublishFolderPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectFolder,
        
        [Parameter(Mandatory = $true)]
        [string]$ProjectName
    )

    try {
        # First try to find the .csproj file
        $csprojPath = Join-Path $ProjectFolder "$ProjectName.csproj"
        if (-not (Test-Path $csprojPath)) {
            Write-Host "Error: Project file not found"
            Write-Host "Hints:"
            Write-Host "  - Check if the project file exists at: $csprojPath"
            Write-Host "  - Verify the project folder and name are correct"
            Write-Host "  - Ensure the project has been built"
            exit 1
        }

        # Look for the publish output directory
        $publishBasePath = Join-Path $ProjectFolder "bin\Release"
        if (-not (Test-Path $publishBasePath)) {
            Write-Host "Error: Release build directory not found"
            Write-Host "Hints:"
            Write-Host "  - Check if the project has been built in Release mode"
            Write-Host "  - Verify the build output directory exists: $publishBasePath"
            Write-Host "  - Ensure the build completed successfully"
            exit 1
        }

        # Find all framework directories and their publish folders
        $frameworkDirs = Get-ChildItem -Path $publishBasePath -Directory
        if (-not $frameworkDirs) {
            Write-Host "Error: No framework directories found"
            Write-Host "Hints:"
            Write-Host "  - Check if the project has been built for any framework"
            Write-Host "  - Verify the build output structure"
            Write-Host "  - Ensure the project targets are correctly configured"
            exit 1
        }

        # Find the most recently modified publish/wwwroot folder
        $publishPaths = $frameworkDirs | ForEach-Object {
            $publishPath = Join-Path $_.FullName "publish\wwwroot"
            if (Test-Path $publishPath) {
                [PSCustomObject]@{
                    Path = $publishPath
                    LastWriteTime = (Get-Item $publishPath).LastWriteTime
                    Framework = $_.Name
                }
            }
        } | Where-Object { $_ -ne $null }

        if (-not $publishPaths) {
            Write-Host "Error: No valid publish directories found"
            Write-Host "Hints:"
            Write-Host "  - Check if the project has been published"
            Write-Host "  - Verify the publish output structure"
            Write-Host "  - Ensure the publish process completed successfully"
            exit 1
        }

        # Get the most recently modified publish folder
        $mostRecent = $publishPaths | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Write-LzAwsVerbose "Found framework: $($mostRecent.Framework)"
        Write-LzAwsVerbose "Using most recent publish folder from: $($mostRecent.LastWriteTime)"

        return (Resolve-Path $mostRecent.Path).Path
    }
    catch {
        Write-Host "Error: Failed to locate publish folder"
        Write-Host "Hints:"
        Write-Host "  - Check if the project structure is correct"
        Write-Host "  - Verify file system permissions"
        Write-Host "  - Ensure all required files are present"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}

function Deploy-WebappAws {
    [CmdletBinding()]
    param( 
        [string]$ProjectFolder="WASMApp",
        [string]$ProjectName="WASMApp"
    )
    try {
        Write-LzAwsVerbose "Starting web application deployment"

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

        Write-LzAwsVerbose "Creating S3 bucket: $BucketName"
        try {
            New-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -BucketType "WEBAPP" -ProfileName $ProfileName
        }
        catch {
            Write-Host "Error: Failed to create S3 bucket"
            Write-Host "Hints:"
            Write-Host "  - Check if you have permission to create S3 buckets"
            Write-Host "  - Verify the bucket name is unique"
            Write-Host "  - Ensure AWS credentials are valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Publish the application
        Write-LzAwsVerbose "Publishing application..."
        try {
            dotnet publish "./$ProjectFolder/$ProjectName.csproj" --configuration Release
            if ($LASTEXITCODE -ne 0) {
                throw "dotnet publish failed with exit code $LASTEXITCODE"
            }
        }
        catch {
            Write-Host "Error: Failed to publish application"
            Write-Host "Hints:"
            Write-Host "  - Check if .NET SDK is installed and up to date"
            Write-Host "  - Verify all required NuGet packages are available"
            Write-Host "  - Review build errors in the output"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
        
        # Get the publish folder path
        try {
            $LocalFolderPath = Get-PublishFolderPath -ProjectFolder "./$ProjectFolder" -ProjectName $ProjectName
            Write-LzAwsVerbose "Using publish folder: $LocalFolderPath"
        }
        catch {
            Write-Host "Error: Failed to locate publish folder"
            Write-Host "Hints:"
            Write-Host "  - Check if the publish process completed successfully"
            Write-Host "  - Verify the project structure is correct"
            Write-Host "  - Ensure all required files are present"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
        
        # Perform the sync operation
        $S3KeyPrefix = "wwwroot"
        $SyncCommand = "aws s3 sync `"$LocalFolderPath`" `"s3://$BucketName/$S3KeyPrefix`" --delete --profile `"$ProfileName`""
        Write-LzAwsVerbose "Running sync command: $SyncCommand"

        try {
            $SyncResult = Invoke-Expression $SyncCommand 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Sync operation failed with exit code $LASTEXITCODE. Error: $SyncResult"
            }
            Write-Host "Successfully deployed web application" -ForegroundColor Green
        }
        catch {
            Write-Host "Error: Failed to sync files to S3"
            Write-Host "Hints:"
            Write-Host "  - Check if you have permission to write to the S3 bucket"
            Write-Host "  - Verify the local files exist and are accessible"
            Write-Host "  - Ensure AWS credentials are valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
    }
    catch {
        Write-Host "Error: An unexpected error occurred during web application deployment"
        Write-Host "Hints:"
        Write-Host "  - Check the AWS S3 console for bucket status"
        Write-Host "  - Verify all required AWS services are available"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}

