<#
.SYNOPSIS
    Resolves the Route 53 public hosted zone ID for a domain name
.DESCRIPTION
    Looks up the public hosted zone ID for the given domain name using
    aws route53 list-hosted-zones-by-name. Returns the zone ID if exactly
    one public hosted zone matches. Throws if none or multiple are found.
.PARAMETER DomainName
    The domain name to look up (e.g., "ezradev.click")
.OUTPUTS
    String - The hosted zone ID (e.g., "Z0661626129XXN634ZB8U")
#>
function Resolve-PublicHostedZoneId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DomainName
    )

    $ProfileName = $script:ProfileName
    $Region = $script:Region

    # Route 53 stores zone names with a trailing dot
    $DnsName = $DomainName.TrimEnd('.') + '.'

    Write-LzAwsVerbose "Looking up Route 53 hosted zone for $DomainName"

    $zonesJson = aws route53 list-hosted-zones-by-name `
        --dns-name $DnsName `
        --max-items 10 `
        --profile $ProfileName `
        --region $Region `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        $errorMessage = @"
Error: Failed to query Route 53 hosted zones
Function: Resolve-PublicHostedZoneId
Domain: $DomainName
Hints:
  - Verify your AWS credentials are valid (aws sso login --profile $ProfileName)
  - Ensure you have route53:ListHostedZonesByName permission
Error Details: $zonesJson
"@
        throw $errorMessage
    }

    $zones = $zonesJson | ConvertFrom-Json

    # Filter to exact domain match and public zones only (no VPCs = public)
    $matchingZones = @()
    foreach ($zone in $zones.HostedZones) {
        if ($zone.Name -eq $DnsName -and -not $zone.Config.PrivateZone) {
            $matchingZones += $zone
        }
    }

    if ($matchingZones.Count -eq 0) {
        $errorMessage = @"
Error: No public Route 53 hosted zone found for '$DomainName'
Function: Resolve-PublicHostedZoneId
Hints:
  - Register or transfer the domain in Route 53 to create a hosted zone
  - Or create a hosted zone manually: aws route53 create-hosted-zone --name $DomainName --caller-reference $(Get-Date -Format o)
  - Verify the domain name in DefaultTenant matches your Route 53 zone
"@
        throw $errorMessage
    }

    if ($matchingZones.Count -gt 1) {
        $zoneIds = ($matchingZones | ForEach-Object { $_.Id -replace '/hostedzone/', '' }) -join ', '
        $errorMessage = @"
Error: Multiple public Route 53 hosted zones found for '$DomainName': $zoneIds
Function: Resolve-PublicHostedZoneId
Hints:
  - Delete duplicate hosted zones in the Route 53 console
  - Or set ECS.PublicHostedZoneId explicitly in systemconfig to pick one
"@
        throw $errorMessage
    }

    # Extract just the zone ID (strip /hostedzone/ prefix)
    $zoneId = $matchingZones[0].Id -replace '/hostedzone/', ''
    Write-LzAwsVerbose "Resolved hosted zone for $DomainName : $zoneId"
    return $zoneId
}
