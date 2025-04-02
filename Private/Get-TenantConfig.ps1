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
        [string]$TenantKey
    )
    
    Write-LzAwsVerbose "Generating kvs entries for tenant $TenantKey"  

    $Config = $script:Config
    $Region = $script:Region
    $SystemKey = $Config.SystemKey
    $SystemSuffix = $Config.SystemSuffix
    $Behaviors = $Config.Behaviors
    $Environment = $Config.Environment  

    # Check that the supplied tenantKey is in the SystemConfig.yaml and grab the tenant properties
    if($Config.Tenants.ContainsKey($TenantKey) -eq $false) {
        throw "The tenant key $TenantKey is not defined in the SystemConfig.yaml file."
        
    }
    $TenantConfig = $Config.Tenants[$TenantKey]

    $TenantConfigOut = @{}

    # Get service stack outputs     
    $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---service")

    # Convert the SystemBehaviors to a HashTable (where the first element in the behavior array is the key))
    $SystemBehaviors = Get-BehaviorsHashTable "{ss}" $Environment $Region $Behaviors $ServiceStackOutputDict 0

    # Generate tenant kvs entry
    $ProcessedTenant = Get-TenantKVSEntry $SystemKey $SystemSuffix $Environment $Region $SystemBehaviors $TenantKey $TenantConfig $ServiceStackOutputDict 

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

    $TenantConfigJson = $TenantConfigOut | ConvertTo-Json -Depth 10  
    return $TenantConfigJson

}