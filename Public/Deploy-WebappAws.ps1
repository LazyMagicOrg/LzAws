<#
.SYNOPSIS
    Publishes a web application to the S3 bucket created by the CDN stack.
.DESCRIPTION
    Builds and deploys a Blazor WASM application to the S3 assets bucket
    managed by the tenant CDN stack ({SystemKey}-{TenantKey}--cdn).
    Reads the bucket name and CloudFront distribution ID from the CDN stack
    outputs, syncs the published files, and invalidates the CloudFront cache.
.PARAMETER TenantKey
    Optional. The tenant key for config file discovery. Auto-detected when
    only one tenant config exists for the current environment.
.PARAMETER ProjectFolder
    The folder containing the web application project (defaults to "WASMApp")
.PARAMETER ProjectName
    The name of the web application project (defaults to "WASMApp")
.EXAMPLE
    Deploy-WebappAws
    Auto-detects tenant config, publishes, syncs to S3, and invalidates CloudFront
.EXAMPLE
    Deploy-WebappAws -TenantKey "ezra"
    Deploys using the specified tenant's CDN stack
.NOTES
    Requires the CDN stack to be deployed first (Deploy-TenantCDNAws).
    Must be run from the webapp Solution root folder.
.OUTPUTS
    Boolean - $true on success, $false on failure
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
        [string]$TenantKey,
        [string]$ProjectFolder="WASMApp",
        [string]$ProjectName="WASMApp"
    )
    try {
        Write-LzAwsVerbose "Starting web application deployment"

        # Load tenant config (sets $script:Config, $script:ProfileName, etc.)
        $null = Get-TenantConfig -TenantKey $TenantKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Account = $script:Account
        $Config = $script:Config
        $SystemKey = $Config.SystemKey
        $TenantKey = $Config.TenantKey

        # Read CDN stack outputs to get the S3 bucket name
        # The bucket is created by the CDN stack (Deploy-TenantCDNAws)
        $CdnStackName = "$SystemKey-$TenantKey--cdn"
        Write-LzAwsVerbose "Reading CDN stack outputs from '$CdnStackName'"
        $CdnOutputs = Get-StackOutputs -SourceStackName $CdnStackName
        $BucketName = $CdnOutputs["AssetsBucketName"]
        $DistributionId = $CdnOutputs["CloudFrontDistributionId"]

        if ([string]::IsNullOrWhiteSpace($BucketName)) {
            $errorMessage = @"
Error: AssetsBucketName not found in CDN stack outputs
Function: Deploy-WebappAws
Hints:
  - Verify the CDN stack '$CdnStackName' was deployed successfully
  - Check the stack outputs in CloudFormation console
  - Ensure Deploy-TenantCDNAws completed before running Deploy-WebappAws
"@
            throw $errorMessage
        }

        Write-LzAwsVerbose "Target S3 bucket: $BucketName"
        Write-LzAwsVerbose "CloudFront distribution: $DistributionId"

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

        # Sync to S3 (under /wwwroot prefix, matching CloudFront OriginPath)
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

        # Invalidate CloudFront cache
        if (-not [string]::IsNullOrWhiteSpace($DistributionId)) {
            Write-LzAwsVerbose "Invalidating CloudFront cache for distribution $DistributionId"
            $InvalidateResult = aws cloudfront create-invalidation --distribution-id $DistributionId --paths "/*" --region $Region --profile $ProfileName 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                Write-Host "Warning: CloudFront invalidation failed (non-fatal): $($InvalidateResult | Out-String)" -ForegroundColor Yellow
            } else {
                Write-LzAwsVerbose "CloudFront invalidation created"
            }
        }

        Write-Host "Successfully deployed web application to $BucketName" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}

