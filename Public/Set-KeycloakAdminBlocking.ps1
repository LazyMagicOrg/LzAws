<#
.SYNOPSIS
    Toggles Keycloak admin path blocking on the public ALB
.DESCRIPTION
    Enables or disables the ALB listener rule that blocks Keycloak admin paths
    (/admin/*, /master/*) on the public ALB. When enabled, admin access is only
    available via the internal ALB (through Tailscale VPN).

    This directly creates or deletes the ALB listener rule for fast toggling
    without a full CloudFormation stack update.
.PARAMETER Disable
    Disable admin blocking (allow public admin access)
.PARAMETER SystemKey
    Optional. The system identifier for config/stack discovery.
.EXAMPLE
    Set-KeycloakAdminBlocking -Disable
    Removes the admin block rule, allowing public access to /admin/*
.EXAMPLE
    Set-KeycloakAdminBlocking
    Creates the admin block rule, restricting /admin/* to VPN access
.NOTES
    - Requires the system stack to be deployed
    - Creates/deletes ALB listener rule at priority 5
    - CloudFormation may detect drift after toggling
.OUTPUTS
    Boolean - $true on success, $false on failure
#>
function Set-KeycloakAdminBlocking {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [switch]$Disable,

        [Parameter(Mandatory=$false)]
        [string]$SystemKey
    )

    try {
        $null = Get-SystemConfig -SystemKey $SystemKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $SystemConfig = $script:SystemConfig
        $SystemKey = $SystemConfig.SystemKey

        $StackName = "$SystemKey---system"
        $SystemStackOutputs = Get-StackOutputs $StackName
        $ListenerArn = $SystemStackOutputs["HttpsListenerArn"]

        if ([string]::IsNullOrWhiteSpace($ListenerArn)) {
            throw "HttpsListenerArn not found in stack outputs for '$StackName'"
        }

        # Find existing admin block rule (priority 5, fixed-response 403)
        $rulesJson = aws elbv2 describe-rules `
            --listener-arn $ListenerArn `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to describe listener rules: $rulesJson"
        }

        $rules = ($rulesJson | ConvertFrom-Json).Rules
        $blockRule = $rules | Where-Object {
            $_.Priority -eq '5' -and
            $_.Actions[0].Type -eq 'fixed-response' -and
            $_.Actions[0].FixedResponseConfig.StatusCode -eq '403'
        }

        if ($Disable) {
            if ($null -ne $blockRule) {
                $null = aws elbv2 delete-rule `
                    --rule-arn $blockRule.RuleArn `
                    --profile $ProfileName `
                    --region $Region 2>&1

                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to delete admin block rule"
                }
                Write-Host "Admin blocking disabled — /admin/* is publicly accessible" -ForegroundColor Yellow
            } else {
                Write-Host "Admin blocking is already disabled" -ForegroundColor Cyan
            }
        } else {
            if ($null -ne $blockRule) {
                Write-Host "Admin blocking is already enabled" -ForegroundColor Cyan
            } else {
                # Get the domain from stack outputs or config
                $SystemDomain = $SystemConfig.SystemDomain
                if ([string]::IsNullOrWhiteSpace($SystemDomain)) {
                    $SystemDomain = $SystemConfig.DefaultTenant
                }

                $null = aws elbv2 create-rule `
                    --listener-arn $ListenerArn `
                    --priority 5 `
                    --conditions "Field=host-header,HostHeaderConfig={Values=[auth.$SystemDomain]}" "Field=path-pattern,PathPatternConfig={Values=[/admin/*,/master/*]}" `
                    --actions "Type=fixed-response,FixedResponseConfig={StatusCode=403,ContentType=text/plain,MessageBody='Access denied. Use VPN for admin access.'}" `
                    --profile $ProfileName `
                    --region $Region 2>&1

                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create admin block rule"
                }
                Write-Host "Admin blocking enabled — /admin/* requires VPN access" -ForegroundColor Green
            }
        }

        return $true
    }
    catch {
        Write-Host ($_.Exception.Message) -ForegroundColor Red
        return $false
    }
}
