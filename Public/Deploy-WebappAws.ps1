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
            $errorMessage = @"
Error: Project file not found
Function: Get-PublishFolderPath
Hints:
  - Check if the project file exists at: $csprojPath
  - Verify the project folder and name are correct
  - Ensure the project has been built
"@
            throw $errorMessage
        }

        # Look for the publish output directory
        $publishBasePath = Join-Path $ProjectFolder "bin\Release"
        if (-not (Test-Path $publishBasePath)) {
            $errorMessage = @"
Error: Release build directory not found
Function: Get-PublishFolderPath
Hints:
  - Check if the project has been built in Release mode
  - Verify the build output directory exists: $publishBasePath
  - Ensure the build completed successfully
"@
            throw $errorMessage
        }

        # Find all framework directories and their publish folders
        $frameworkDirs = Get-ChildItem -Path $publishBasePath -Directory
        if (-not $frameworkDirs) {
            $errorMessage = @"
Error: No framework directories found
Function: Get-PublishFolderPath
Hints:
  - Check if the project has been built for any framework
  - Verify the build output structure
  - Ensure the project targets are correctly configured
"@
            throw $errorMessage
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
            $errorMessage = @"
Error: No valid publish directories found
Function: Get-PublishFolderPath
Hints:
  - Check if the project has been published
  - Verify the publish output structure
  - Ensure the publish process completed successfully
"@
            throw $errorMessage
        }

        # Get the most recently modified publish folder
        $mostRecent = $publishPaths | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Write-LzAwsVerbose "Found framework: $($mostRecent.Framework)"
        Write-LzAwsVerbose "Using most recent publish folder from: $($mostRecent.LastWriteTime)"

        return (Resolve-Path $mostRecent.Path).Path
    }
    catch {
        $errorMessage = @"
Error: Failed to locate publish folder
Function: Get-PublishFolderPath
Hints:
  - Check if the project structure is correct
  - Verify file system permissions
  - Ensure all required files are present
Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
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
Function: Deploy-WebappAws
Hints:
  - Check if apppublish.json exists in: $AppPublishPath
  - Verify the project folder is correct
  - Ensure the configuration file is present
"@
            throw $errorMessage
        }

        $AppPublish = Get-Content -Path $AppPublishPath -Raw | ConvertFrom-Json
        if ($null -eq $AppPublish.AppName) {
            $errorMessage = @"
Error: Invalid apppublish.json format
Function: Deploy-WebappAws
Hints:
  - Check if AppName is defined in apppublish.json
  - Verify the JSON format is valid
  - Ensure all required fields are present
"@
            throw $errorMessage
        }

        $AppName = $AppPublish.AppName
        $BucketName = "$SystemKey---webapp-$AppName-$SystemSuffix"

        Write-LzAwsVerbose "Creating S3 bucket: $BucketName"
        New-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -BucketType "WEBAPP" -ProfileName $ProfileName

        # Publish the application
        Write-LzAwsVerbose "Publishing application..."
        $result = dotnet publish "./$ProjectFolder/$ProjectName.csproj" --configuration Release 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $errorMessage = @"
Error: Failed to publish application
Function: Deploy-WebappAws
Hints:
  - Check if .NET SDK is installed and up to date
  - Verify all required NuGet packages are available
  - Review build errors in the output
Error Details: dotnet publish failed with exit code $exitCode
Command Output: $($result | Out-String)
"@
                throw $errorMessage
        }
        
        # Get the publish folder path
        $LocalFolderPath = Get-PublishFolderPath -ProjectFolder "./$ProjectFolder" -ProjectName $ProjectName
        Write-LzAwsVerbose "Using publish folder: $LocalFolderPath"
        
        # Perform the sync operation
        $S3KeyPrefix = "wwwroot"
        $SyncCommand = "aws s3 sync `"$LocalFolderPath`" `"s3://$BucketName/$S3KeyPrefix`" --delete --region $Region --profile `"$ProfileName`""
        Write-LzAwsVerbose "Running sync command: $SyncCommand"

        $SyncResult = Invoke-Expression $SyncCommand 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $errorMessage = @"
Error: Failed to sync files to S3
Function: Deploy-WebappAws
Hints:
  - Check if you have permission to write to the S3 bucket
  - Verify the local files exist and are accessible
  - Ensure AWS credentials are valid
Error Details: Sync operation failed with exit code $exitCode
Command Output: $($SyncResult | Out-String)
"@
            throw $errorMessage
        }
        Write-Host "Successfully deployed web application" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}

