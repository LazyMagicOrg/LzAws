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

    # First try to find the .csproj file
    $csprojPath = Join-Path $ProjectFolder "$ProjectName.csproj"
    if (-not (Test-Path $csprojPath)) {
        throw "Project file not found at: $csprojPath"
    }

    # Look for the publish output directory
    $publishBasePath = Join-Path $ProjectFolder "bin\Release"
    if (-not (Test-Path $publishBasePath)) {
        throw "Release build directory not found at: $publishBasePath"
    }

    # Find all framework directories and their publish folders
    $frameworkDirs = Get-ChildItem -Path $publishBasePath -Directory
    if (-not $frameworkDirs) {
        throw "No framework directories found in: $publishBasePath"
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
        throw "No valid publish directories found in any framework folder"
    }

    # Get the most recently modified publish folder
    $mostRecent = $publishPaths | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-LzAwsVerbose "Found framework: $($mostRecent.Framework)"
    Write-LzAwsVerbose "Using most recent publish folder from: $($mostRecent.LastWriteTime)"

    return (Resolve-Path $mostRecent.Path).Path
}

function Deploy-WebappAws {
    [CmdletBinding()]
    param( 
        [string]$ProjectFolder="WASMApp",
        [string]$ProjectName="WASMApp"
    )
    try {
        $SystemConfig = Get-SystemConfig
        $Region = $SystemConfig.Region
        $Account = $SystemConfig.Account      
        $ProfileName = $SystemConfig.Config.Profile
        $SystemKey = $SystemConfig.Config.SystemKey
        $SystemSuffix = $SystemConfig.Config.SystemSuffix
        
        $AppPublish = Get-Content -Path "./$ProjectFolder/apppublish.json" -Raw | ConvertFrom-Json
        $AppName = $AppPublish.AppName
        $BucketName = "$SystemKey---webapp-$AppName-$SystemSuffix"

        Write-Host $BucketName

        New-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -BucketType "WEBAPP" -ProfileName $ProfileName

        # Publish the application
        Write-LzAwsVerbose "Publishing application..."
        dotnet publish "./$ProjectFolder/$ProjectName.csproj" --configuration Release
        
        # Get the publish folder path using our new function
        $LocalFolderPath = Get-PublishFolderPath -ProjectFolder "./$ProjectFolder" -ProjectName $ProjectName
        Write-LzAwsVerbose "Using publish folder: $LocalFolderPath"
        
        # Perform the sync operation
        $S3KeyPrefix = "wwwroot"
        $SyncCommand = "aws s3 sync `"$LocalFolderPath`" `"s3://$BucketName/$S3KeyPrefix`" --delete --profile `"$ProfileName`""
        Write-Host "Running sync command: $SyncCommand"

        try {
            $SyncResult = Invoke-Expression $SyncCommand 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Sync operation failed with exit code $LASTEXITCODE. Error: $SyncResult"
            }
            Write-Host "Sync completed successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "Error during sync operation: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Full Error Details: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    catch {
        throw
    }
}

