<#
.SYNOPSIS
    Deploys the tenant authentication stack
.DESCRIPTION
    Deploys or updates the tenant authentication stack which registers a tenant's
    domain with the system Keycloak instance. When the tenant domain differs
    from the system domain, creates ALB listener rules and DNS records. When
    domains match (dev environment), this is a no-op stack.
.EXAMPLE
    Deploy-TenantAuthAws
    Deploys the tenant auth stack based on tenantconfig.yaml
.NOTES
    - Must be run from the AWSTemplates directory
    - Requires the system stack deployed first
.OUTPUTS
    Boolean - $true on success, $false on failure
#>
function Deploy-TenantAuthAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TenantKey
    )
    Write-LzAwsVerbose "Deploy-TenantAuthAws"
    try {
        $null = Get-TenantConfig -TenantKey $TenantKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $TenantKey = $Config.TenantKey
        $TenantSuffix = $Config.TenantSuffix

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.tenant-auth.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.tenant-auth.yaml
Function: Deploy-TenantAuthAws
Hints:
  - Check if the template file exists in the Templates directory
  - Ensure you are running from the AWSTemplates directory
"@
            throw $errorMessage
        }

        # Get system stack outputs
        $SystemKey = $Config.SystemKey
        if ([string]::IsNullOrWhiteSpace($SystemKey)) {
            throw "SystemKey not found in tenantconfig. Add 'SystemKey' to your tenantconfig file."
        }

        $StackName = $SystemKey + "-" + $TenantKey + "--auth"
        $ArtifactsBucket = $SystemKey + "-" + $TenantKey + "--artifacts-" + $TenantSuffix
        $SystemStackName = $SystemKey + "---system"
        Write-LzAwsVerbose "Getting system stack outputs from '$SystemStackName'"
        $SystemStackOutputDict = Get-StackOutputs $SystemStackName

        # Determine the system domain from the systemconfig
        # We need to load it to get SystemDomain — pass SystemKey for multi-system support
        $null = Get-SystemConfig -SystemKey $SystemKey
        $SystemDomain = $script:SystemConfig.SystemDomain

        # Build parameters
        $ParametersDict = @{
            "TenantKeyParameter"         = $TenantKey
            "SystemKeyParameter"       = $SystemKey
            "TenantDomainParameter"      = $Config.DefaultTenant
            "SystemDomainParameter"    = $SystemDomain
        }

        # Add system stack outputs as parameters
        foreach ($OutputKey in $SystemStackOutputDict.Keys) {
            $ParameterName = $OutputKey + "Parameter"
            if (-not $ParametersDict.ContainsKey($ParameterName)) {
                $ParametersDict[$ParameterName] = $SystemStackOutputDict[$OutputKey]
                Write-LzAwsVerbose "Added system stack output: $ParameterName"
            }
        }

        # Map specific system outputs to tenant auth parameter names
        # KeycloakTargetGroupArn → KeycloakTargetGroupArnParameter
        # KeycloakInternalTargetGroupArn → KeycloakInternalTargetGroupArnParameter
        # (These should be mapped by the foreach loop above)

        # Per-tenant resource isolation: auth listener priorities
        $EcsConfig = $Config.ECS
        if ($null -ne $EcsConfig) {
            $ListenerPriorities = $EcsConfig.ListenerPriorities
            if ($null -ne $ListenerPriorities) {
                if ($ListenerPriorities.Auth) {
                    $ParametersDict["AuthListenerPriorityParameter"] = [string]$ListenerPriorities.Auth
                }
                if ($ListenerPriorities.Realms) {
                    $ParametersDict["RealmsListenerPriorityParameter"] = [string]$ListenerPriorities.Realms
                }
                if ($ListenerPriorities.InternalAuth) {
                    $ParametersDict["InternalAuthListenerPriorityParameter"] = [string]$ListenerPriorities.InternalAuth
                }
                if ($ListenerPriorities.InternalRealms) {
                    $ParametersDict["InternalRealmsListenerPriorityParameter"] = [string]$ListenerPriorities.InternalRealms
                }
            }
        }

        # Filter to only parameters the template expects
        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.tenant-auth.yaml"
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

        # Deploy
        Write-Host "Deploying stack $StackName"
        $result = sam deploy `
            --template-file Templates/sam.tenant-auth.yaml `
            --stack-name $StackName `
            --parameter-overrides $Parameters `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
            --region $Region `
            --profile $ProfileName 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $resultString = $result | Out-String
            if ($resultString -match "No changes to deploy") {
                Write-LzAwsVerbose "No changes to deploy. Stack is up to date."
            } else {
                $errorMessage = @"
Error: SAM deployment failed
Function: Deploy-TenantAuthAws
Error Details: $resultString
"@
                throw $errorMessage
            }
        }

        # Check if this was a no-op
        $TenantDomain = $Config.DefaultTenant
        if ($TenantDomain -eq $SystemDomain) {
            Write-Host "Tenant auth: no-op (tenant domain matches system domain)" -ForegroundColor Cyan
        } else {
            Write-Host "Tenant auth: created ALB rules and DNS for auth.$TenantDomain" -ForegroundColor Green
        }

        Write-Host "Deploy-TenantAuthAws completed" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
