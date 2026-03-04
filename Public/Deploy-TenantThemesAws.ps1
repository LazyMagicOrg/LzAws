<#
.SYNOPSIS
    Deploys Keycloak themes to EFS via an ECS init task
.DESCRIPTION
    Deploys or updates the tenant themes stack which creates an ECS task
    definition for copying Keycloak theme files to EFS. If theme assets
    exist at Assets/KeycloakThemes/, tars them up, uploads to S3, deploys
    the CloudFormation stack, and runs the init task.

    Graceful no-op: if no Assets/KeycloakThemes/ directory exists or it
    contains no files, returns $true without deploying anything.
.EXAMPLE
    Deploy-TenantThemesAws
    Deploys the tenant themes stack based on tenantconfig.yaml
.NOTES
    - Must be run from the AWSTemplates directory
    - Requires the system stack deployed first (Deploy-SystemAws)
.OUTPUTS
    Boolean - $true on success, $false on failure
#>
function Deploy-TenantThemesAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TenantKey
    )

    Write-LzAwsVerbose "Deploy-TenantThemesAws"

    try {
        $null = Get-TenantConfig -TenantKey $TenantKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $TenantKey = $Config.TenantKey
        $TenantSuffix = $Config.TenantSuffix

        # =====================================================================
        # Graceful no-op: skip if no theme assets exist
        # =====================================================================
        $ThemeAssetsDir = "Assets/KeycloakThemes"
        if (-not (Test-Path -Path $ThemeAssetsDir -PathType Container)) {
            Write-Host "No Keycloak theme assets found at $ThemeAssetsDir — skipping themes deployment" -ForegroundColor Cyan
            return $true
        }

        # Check if the directory has any theme files (ignore docker-compose.yml etc. at root)
        $themeSubDirs = Get-ChildItem -Path $ThemeAssetsDir -Directory
        if ($null -eq $themeSubDirs -or $themeSubDirs.Count -eq 0) {
            Write-Host "No theme subdirectories found in $ThemeAssetsDir — skipping themes deployment" -ForegroundColor Cyan
            return $true
        }

        Write-LzAwsVerbose "Found $($themeSubDirs.Count) theme(s) in $ThemeAssetsDir"

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.tenant-themes.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.tenant-themes.yaml
Function: Deploy-TenantThemesAws
Hints:
  - Check if the template file exists in the Templates directory
  - Verify the template file name is correct
  - Ensure you are running from the AWSTemplates directory
"@
            throw $errorMessage
        }

        # Get system stack outputs
        $SystemKey = $Config.SystemKey
        if ([string]::IsNullOrWhiteSpace($SystemKey)) {
            $errorMessage = @"
Error: SystemKey not found in tenantconfig
Function: Deploy-TenantThemesAws
Hints:
  - Add 'SystemKey: "ezra"' to your tenantconfig file
  - SystemKey identifies which system stack to read outputs from
"@
            throw $errorMessage
        }

        $StackName = $SystemKey + "-" + $TenantKey + "--themes"
        $ArtifactsBucket = $SystemKey + "-" + $TenantKey + "--artifacts-" + $TenantSuffix
        $Account = $script:Account

        # Create S3 artifacts bucket if it doesn't exist
        Write-LzAwsVerbose "Ensuring S3 artifacts bucket exists: $ArtifactsBucket"
        New-LzAwsS3Bucket -BucketName $ArtifactsBucket -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName

        $SystemStackName = $SystemKey + "---system"
        Write-LzAwsVerbose "Getting system stack outputs from '$SystemStackName'"
        $SystemStackOutputDict = Get-StackOutputs $SystemStackName

        if ($null -eq $SystemStackOutputDict -or $SystemStackOutputDict.Count -eq 0) {
            $errorMessage = @"
Error: System stack '$SystemStackName' not found or has no outputs
Function: Deploy-TenantThemesAws
Hints:
  - Deploy the system stack first: Deploy-SystemAws
  - Verify the system stack name is correct
  - Check if the system stack deployed successfully
"@
            throw $errorMessage
        }

        # =====================================================================
        # Upload theme tarball to S3 and generate pre-signed URL
        # =====================================================================
        $S3ThemeKey = "keycloak-themes/themes.tar.gz"
        $TarballPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "keycloak-themes.tar.gz")

        try {
            Write-LzAwsVerbose "Creating theme tarball from $ThemeAssetsDir"
            tar czf $TarballPath -C $ThemeAssetsDir .
            if ($LASTEXITCODE -ne 0) {
                throw "tar command failed with exit code $LASTEXITCODE"
            }

            Write-LzAwsVerbose "Uploading theme tarball to s3://$ArtifactsBucket/$S3ThemeKey"
            aws s3 cp $TarballPath "s3://$ArtifactsBucket/$S3ThemeKey" --region $Region --profile $ProfileName
            if ($LASTEXITCODE -ne 0) {
                throw "S3 upload failed with exit code $LASTEXITCODE"
            }

            $ThemePreSignedUrl = aws s3 presign "s3://$ArtifactsBucket/$S3ThemeKey" --expires-in 3600 --region $Region --profile $ProfileName
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ThemePreSignedUrl)) {
                throw "Failed to generate pre-signed URL for theme tarball"
            }
            Write-LzAwsVerbose "Generated pre-signed URL for Keycloak theme tarball"
        }
        finally {
            Remove-Item -Path $TarballPath -Force -ErrorAction SilentlyContinue
        }

        # =====================================================================
        # Build parameters dict
        # =====================================================================
        $ParametersDict = @{
            "TenantKeyParameter"         = $TenantKey
            "SystemKeyParameter"         = $SystemKey
            "KeycloakThemeUrlParameter"  = $ThemePreSignedUrl
        }

        # Map all system stack outputs as parameters
        foreach ($OutputKey in $SystemStackOutputDict.Keys) {
            $ParameterName = $OutputKey + "Parameter"
            if (-not $ParametersDict.ContainsKey($ParameterName)) {
                $ParametersDict[$ParameterName] = $SystemStackOutputDict[$OutputKey]
                Write-LzAwsVerbose "Added system stack output: $ParameterName"
            }
        }

        # Add ECS config overrides (LogRetentionDays)
        $EcsConfig = $Config.ECS
        if ($null -ne $EcsConfig) {
            if ($EcsConfig.LogRetentionDays) {
                $ParametersDict["LogRetentionDaysParameter"] = [string]$EcsConfig.LogRetentionDays
            }
        }

        # =====================================================================
        # Filter parameters and deploy
        # =====================================================================

        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.tenant-themes.yaml"
        $FilteredParametersDict = @{}
        foreach ($Key in $ParametersDict.Keys) {
            if ($TemplateParameters -contains $Key) {
                $FilteredParametersDict[$Key] = $ParametersDict[$Key]
                Write-LzAwsVerbose "Including parameter: $Key"
            } else {
                Write-LzAwsVerbose "Skipping parameter not in template: $Key"
            }
        }

        $Parameters = ConvertTo-ParameterOverrides -parametersDict $FilteredParametersDict

        # Deploy the tenant themes stack
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName"
        $result = sam deploy `
            --template-file Templates/sam.tenant-themes.yaml `
            --s3-bucket $ArtifactsBucket `
            --stack-name $StackName `
            --parameter-overrides $Parameters `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM `
            --profile $ProfileName `
            --region $Region 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $resultString = $result | Out-String

            if ($resultString -match "No changes to deploy") {
                Write-LzAwsVerbose "No changes to deploy. Stack is up to date."
            } else {
                $errorMessage = @"
Error: SAM deployment failed
Function: Deploy-TenantThemesAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the template syntax is correct
Error Details: SAM deployment failed with exit code $exitCode
Command Output: $resultString
"@
                throw $errorMessage
            }
        }

        Write-Host "Deploy-TenantThemesAws stack deployed successfully" -ForegroundColor Green

        # =====================================================================
        # Run the theme init task
        # =====================================================================
        Write-LzAwsVerbose "Running Keycloak theme initialization task"

        $clusterArn = $SystemStackOutputDict["EcsClusterArn"]
        $subnet1 = $SystemStackOutputDict["PrivateSubnet1Id"]
        $subnet2 = $SystemStackOutputDict["PrivateSubnet2Id"]
        $securityGroup = $SystemStackOutputDict["EcsPublicSecurityGroupId"]

        if (-not [string]::IsNullOrEmpty($clusterArn) -and
            -not [string]::IsNullOrEmpty($subnet1) -and
            -not [string]::IsNullOrEmpty($securityGroup)) {

            $taskFamily = "$SystemKey-$TenantKey-keycloak-theme-init"

            $initResult = Invoke-EcsInitTask `
                -TaskFamily $taskFamily `
                -ClusterArn $clusterArn `
                -Subnets "$subnet1,$subnet2" `
                -SecurityGroup $securityGroup `
                -Description "Keycloak theme initialization"

            if (-not $initResult) {
                Write-Host "Warning: Keycloak theme initialization task failed. Check CloudWatch logs." -ForegroundColor Yellow
            }
        } else {
            Write-LzAwsVerbose "Skipping theme init: required system outputs not found"
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    Write-Host "Deploy-TenantThemesAws completed"
    return $true
}
