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

    # Call Get-SystemConfig but discard its output
    $null = Get-SystemConfig # sets script scopevariables
    $Region = $script:Region
    $Account = $script:Account    
    $ProfileName = $script:ProfileName
    $Config = $script:Config

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
    $mostRecentPath = $null
    $mostRecentTime = [DateTime]::MinValue

    foreach ($dir in $frameworkDirs) {
        $publishPath = Join-Path $dir.FullName "publish\wwwroot"
        if (Test-Path $publishPath) {
            $lastWriteTime = (Get-Item $publishPath).LastWriteTime
            if ($lastWriteTime -gt $mostRecentTime) {
                $mostRecentTime = $lastWriteTime
                $mostRecentPath = $publishPath
            }
        }
    }

    if (-not $mostRecentPath) {
        throw "No valid publish directories found in any framework folder"
    }

    Write-LzAwsVerbose "Using most recent publish folder from: $mostRecentTime"

    # Get the resolved path and ensure it's a string
    $resolvedPath = (Resolve-Path $mostRecentPath).Path
    Write-Debug "Resolved path type: $($resolvedPath.GetType().FullName)"
    Write-Debug "Resolved path value: $resolvedPath"
    return $resolvedPath
}

function Deploy-WebappAws {
    [CmdletBinding()]
    param( 
        [string]$ProjectFolder="WASMApp",
        [string]$ProjectName="WASMApp"
    )
    try {
        Get-SystemConfig # sets script scopevariables
        $Region = $script:Region
        $Account = $script:Account    
        $ProfileName = $script:ProfileName
        $Config = $script:Config

        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix
        
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
        Write-Debug "LocalFolderPath type: $($LocalFolderPath.GetType().FullName)"
        Write-Debug "LocalFolderPath value: $LocalFolderPath"
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

