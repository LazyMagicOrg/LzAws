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
function Deploy-WebappAws {
    [CmdletBinding()]
    param( 
        [string]$ProjectFolder="WASMApp",
        [string]$ProjectName="WASMApp"
    )
    $SystemConfig = Get-SystemConfig
    $ProfileName = $SystemConfig.Config.Profile
    $SystemKey = $SystemConfig.Config.SystemKey
    $SystemSuffix = $SystemConfig.Config.SystemSuffix
    
    $AppPublish = Get-Content -Path "./$ProjectFolder/apppublish.json" -Raw | ConvertFrom-Json
    $AppName = $AppPublish.AppName
    $BucketName = "$SystemKey---webapp-$AppName-$SystemSuffix"
    Write-Host $BucketName

    dotnet publish "./$ProjectFolder/$ProjectName.csproj" --configuration Release
    $ProjectXml = [xml](Get-Content "./$ProjectFolder/$ProjectName.csproj")
    $Framework = $ProjectXml.Project.PropertyGroup.TargetFramework     
    $LocalFolderPath = "./$ProjectFolder/bin/Release/$Framework/publish/wwwroot"
    $LocalFolderPath = Resolve-Path $LocalFolderPath
   
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

