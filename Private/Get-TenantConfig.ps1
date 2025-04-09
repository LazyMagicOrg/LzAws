# This script generates tenant config json from the tenant and 
# subtenant information in the systemconfig.yaml file. 
#
# Each tenant config object contains the 
# KVS entry we publish to the CloudFront KVS.
# The structure of the tenant config object is:
#   {
#       "domain" :  
#       {
#           "systemKey": string,
#           "tenantKey": string,
#           "subtenantKey": string,
#           "ss" : string,
#           "ts" : string,
#           "sts" : string,
#           "env" : string,
#           "region" : string,
#           "behaviors" : [...]
#       }
#   }
# For a tenant entry, the domain is the root domain. ex: example.com
# foa a subtenant entry, the domain includes the subdomain. ex: store1.example.com
#

function Get-TenantConfig {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantKey
    )
    

    Write-LzAwsVerbose "Generating kvs entries for tenant '$TenantKey'"

    $ProfileName = $script:ProfileName  
    $Region = $script:Region
    $Config = $script:Config
    $SystemKey = $Config.SystemKey
    $SystemSuffix = $Config.SystemSuffix
    $Behaviors = $Config.Behaviors
    $Environment = $Config.Environment

    # Check that the supplied tenantKey is in the SystemConfig.yaml and grab the tenant properties
    if($Config.Tenants.ContainsKey($TenantKey) -eq $false) {
        $errorMessage = @"
Error: Tenant '$TenantKey' is not defined in the SystemConfig.yaml file
Function: Get-TenantConfig
Hints:
- Check if the tenant is defined in systemconfig.yaml
- Verify the tenant key is spelled correctly
- Ensure the tenant configuration is properly formatted
"@
        throw $errorMessage
    }
    $TenantConfig = $Config.Tenants[$TenantKey]

    $TenantConfigOut = @{}

    # Get service stack outputs     
    $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---service")

    # Convert the SystemBehaviors to a HashTable
    try {
        $SystemBehaviors = Get-BehaviorsHashTable "{ss}" $Environment $Region $Behaviors $ServiceStackOutputDict 0
    }
    catch {
        $errorMessage = @"
Error: Failed to process system behaviors
Function: Get-TenantConfig
Hints:
- Check if behaviors are properly defined in systemconfig.yaml
- Verify the behavior format is correct
- Ensure all required behavior properties are present
- Review the behavior configuration syntax

Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
    }

    # Generate tenant kvs entry
    try {
        $ProcessedTenant = Get-TenantKVSEntry $SystemKey $SystemSuffix $Environment $Region $SystemBehaviors $TenantKey $TenantConfig $ServiceStackOutputDict 
    }
    catch {
        $errorMessage = @"
Error: Failed to generate tenant KVS entry for tenant '$TenantKey'
Function: Get-TenantConfig
Hints:
- Check tenant configuration in systemconfig.yaml
- Verify all required tenant properties are present
- Ensure the tenant domain is properly configured
- Review the tenant's root domain settings

Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
    }

    # Create and append the tenant kvs entry
    $TenantConfigOut[$TenantConfig.RootDomain] = $ProcessedTenant
    $ProcessedTenantJson = $ProcessedTenant | ConvertTo-Json -Compress -Depth 10    
    Write-LzAwsVerbose $ProcessedTenantJson
    Write-LzAwsVerbose $ProcessedTenantJson.Length

    # GetAsset Names allows us to see the asset names that will be created for the tenant kvs entry
    $Assetnames = Get-AssetNames $ProcessedTenant $true
    Write-LzAwsVerbose "Tenant Asset Names"
    foreach($AssetName in $Assetnames) {
        Write-LzAwsVerbose $AssetName
    }

    # Generate subtenant kvs entries
    Write-LzAwsVerbose "Processing SubTenants"
    $Subtenants = @()
    foreach($Subtenant in $TenantConfig.SubTenants.GetEnumerator()) {
        try {
            $ProcessedSubtenant = Get-SubtenantKVSEntry $ProcessedTenant $Subtenant.Value $Subtenant.Key $ServiceStackOutputDict
            $TenantConfigOut[$Subtenant.Value.Subdomain + "." + $TenantConfig.RootDomain] = $ProcessedSubtenant
            $ProcessedSubtenantJson = $ProcessedSubtenant | ConvertTo-Json -Compress -Depth 10  
            Write-LzAwsVerbose $ProcessedSubtenantJson
            Write-LzAwsVerbose $ProcessedSubtenantJson.Length
            $Subtenants += $ProcessedSubtenant

            $Assetnames = Get-AssetNames $ProcessedSubtenant 2 $true
            Write-LzAwsVerbose "Subtenant Asset Names"
            foreach($AssetName in $Assetnames) {
                Write-LzAwsVerbose $AssetName
            }
        }
        catch {
            $errorMessage = @"
Error: Failed to process subtenant '$($Subtenant.Key)'
Function: Get-TenantConfig
Hints:
- Check subtenant configuration in systemconfig.yaml
- Verify all required subtenant properties are present
- Ensure the subtenant domain is properly configured
- Review the subtenant's domain and behavior settings

Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }
    }

    $TenantConfigJson = $TenantConfigOut | ConvertTo-Json -Depth 10  
    return $TenantConfigJson

}