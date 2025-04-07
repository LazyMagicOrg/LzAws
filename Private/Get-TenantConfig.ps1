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
    
    try {
        Write-LzAwsVerbose "Generating kvs entries for tenant '$TenantKey'"

        try {
            $SystemConfig = Get-SystemConfig 
            $Config = $SystemConfig.Config
            $Region = $SystemConfig.Region
            $SystemKey = $Config.SystemKey
            $SystemSuffix = $Config.SystemSuffix
            $Behaviors = $Config.Behaviors
            $Environment = $Config.Environment  
        }
        catch {
            Write-Host "Error: Failed to load system configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if systemconfig.yaml exists and is valid"
            Write-Host "  - Verify AWS credentials are properly configured"
            Write-Host "  - Ensure you have sufficient permissions"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to load system configuration: $($_.Exception.Message)" -ErrorAction Stop
        }

        # Check that the supplied tenantKey is in the SystemConfig.yaml and grab the tenant properties
        if($Config.Tenants.ContainsKey($TenantKey) -eq $false) {
            Write-Host "Error: Tenant '$TenantKey' is not defined in the SystemConfig.yaml file"
            Write-Host "Hints:"
            Write-Host "  - Check if the tenant is defined in systemconfig.yaml"
            Write-Host "  - Verify the tenant key is spelled correctly"
            Write-Host "  - Ensure the tenant configuration is properly formatted"
            Write-Error "Tenant '$TenantKey' is not defined in the SystemConfig.yaml file" -ErrorAction Stop
        }
        $TenantConfig = $Config.Tenants[$TenantKey]

        $TenantConfigOut = @{}

        # Get service stack outputs     
        try {
            $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---service")
        }
        catch {
            Write-Host "Error: Failed to get service stack outputs"
            Write-Host "Hints:"
            Write-Host "  - Check if the service stack exists"
            Write-Host "  - Verify the stack name is correct"
            Write-Host "  - Ensure the stack has outputs defined"
            Write-Host "Stack: $($Config.SystemKey)---service"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to get service stack outputs for stack '$($Config.SystemKey)---service': $($_.Exception.Message)" -ErrorAction Stop
        }

        # Convert the SystemBehaviors to a HashTable
        try {
            Write-Host "debug Get-TenantConfig"
            $SystemBehaviors = Get-BehaviorsHashTable "{ss}" $Environment $Region $Behaviors $ServiceStackOutputDict 0
        }
        catch {
            Write-Host "Error: Failed to process system behaviors"
            Write-Host "Hints:"
            Write-Host "  - Check if behaviors are properly defined in systemconfig.yaml"
            Write-Host "  - Verify the behavior format is correct"
            Write-Host "  - Ensure all required behavior properties are present"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to process system behaviors: $($_.Exception.Message)" -ErrorAction Stop
        }

        # Generate tenant kvs entry
        try {
            $ProcessedTenant = Get-TenantKVSEntry $SystemKey $SystemSuffix $Environment $Region $SystemBehaviors $TenantKey $TenantConfig $ServiceStackOutputDict 
        }
        catch {
            Write-Host "Error: Failed to generate tenant KVS entry"
            Write-Host "Hints:"
            Write-Host "  - Check tenant configuration in systemconfig.yaml"
            Write-Host "  - Verify all required tenant properties are present"
            Write-Host "  - Ensure the tenant domain is properly configured"
            Write-Host "Tenant: $TenantKey"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to generate tenant KVS entry for tenant '$TenantKey': $($_.Exception.Message)" -ErrorAction Stop
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
                Write-Host "Error: Failed to process subtenant '$($Subtenant.Key)'"
                Write-Host "Hints:"
                Write-Host "  - Check subtenant configuration in systemconfig.yaml"
                Write-Host "  - Verify all required subtenant properties are present"
                Write-Host "  - Ensure the subtenant domain is properly configured"
                Write-Host "Subtenant: $($Subtenant.Key)"
                Write-Host "Error Details: $($_.Exception.Message)"
                Write-Error "Failed to process subtenant '$($Subtenant.Key)': $($_.Exception.Message)" -ErrorAction Stop
            }
        }

        $TenantConfigJson = $TenantConfigOut | ConvertTo-Json -Depth 10  
        return $TenantConfigJson
    }
    catch {
        Write-Host "Error: Failed to generate tenant configuration"
        Write-Host "Hints:"
        Write-Host "  - Check system configuration and tenant settings"
        Write-Host "  - Verify AWS service status"
        Write-Host "  - Ensure all required resources are available"
        Write-Host "Tenant: $TenantKey"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "Failed to generate tenant configuration for tenant '$TenantKey': $($_.Exception.Message)" -ErrorAction Stop
    }
}