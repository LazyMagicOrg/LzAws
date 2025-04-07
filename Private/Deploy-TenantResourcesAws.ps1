function Deploy-TenantResourcesAws {
    # This function deploys AWS resources for a tenant including:
    # - S3 buckets for assets
    # - DynamoDB tables 
    # - CloudFront KeyValueStore entries
    # Resources are created for both the tenant and any subtenants
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true)]
        [string]$TenantKey,
        [switch]$ReportOnly
    )

    try {
        $SystemConfig = Get-SystemConfig 
        $Region = $SystemConfig.Region
        $Account = $SystemConfig.Account
        $Config = $SystemConfig.Config
        $ProfileName = $SystemConfig.ProfileName

        Write-LzAwsVerbose "Region: $Region, Account: $Account"
        
        # Validate tenant exists in config
        if(-not $Config.Tenants.ContainsKey($TenantKey)) {
            Write-Host "Error: Tenant '$TenantKey' not found in configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if the tenant key is correct"
            Write-Host "  - Verify the tenant is defined in systemconfig.yaml"
            Write-Host "  - Ensure you're using the correct system configuration"
            Write-Error "Tenant '$TenantKey' not found in configuration" -ErrorAction Stop
        }

        # Get tenant config and KVS ARN
        try {
            $KvsEntriesJson = Get-TenantConfig $TenantKey 
            $KvsEntries = ConvertFrom-Json $KvsEntriesJson -Depth 10

            $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---system")
            $KvsArn = $ServiceStackOutputDict["KeyValueStoreArn"]
        }
        catch {
            Write-Host "Error: Failed to load tenant configuration for '$TenantKey'"
            Write-Host "Hints:"
            Write-Host "  - Check if the tenant configuration exists"
            Write-Host "  - Verify the system stack is deployed"
            Write-Host "  - Ensure the KeyValueStore is properly configured"
            Write-Error "Failed to load tenant configuration for '$TenantKey': $($_.Exception.Message)" -ErrorAction Stop
        }

        # Process each domain in tenant config
        foreach($Property in $KvsEntries.PSObject.Properties) {
            $Domain = $Property.Name
            Write-LzAwsVerbose "Processing $Domain"
            
            # Determine domain level (1 = example.com, 2 = sub.example.com)
            $Level = ($Domain.ToCharArray() | Where-Object { $_ -eq '.' } | Measure-Object).Count
            $KvsEntry = $Property.Value

            # Create asset buckets
            Write-LzAwsVerbose "Creating S3 buckets"
            Write-LzAwsVerbose ($KvsEntry | ConvertTo-Json -Depth 10)
            $AssetNames = Get-AssetNames $KvsEntry -ReportOnly $ReportOnly -S3Only $true
            foreach($AssetName in $AssetNames) {
                if($ReportOnly) {
                    Write-Host "   $AssetName"
                } else { 
                    Write-LzAwsVerbose "   $AssetName"
                    try {
                        New-LzAwsS3Bucket -BucketName $AssetName -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName
                    }
                    catch {
                        Write-Host "Error: Failed to create assets bucket '$AssetName' for tenant '$TenantKey'"
                        Write-Host "Hints:"
                        Write-Host "  - Check if you have sufficient AWS permissions"
                        Write-Host "  - Verify the bucket name is unique in your AWS account"
                        Write-Host "  - Ensure the region is valid and accessible"
                        Write-Error "Failed to create assets bucket '$AssetName' for tenant '$TenantKey': $($_.Exception.Message)" -ErrorAction Stop
                    }
                }
            }

            # Create DynamoDB table
            $TableName = $Config.SystemKey + "_" + $TenantKey
            if($Level -eq 2) {
                $TableName += "_" + $KvsEntry.subtenantKey
            }
            if($ReportOnly) {
                Write-Host "Creating DynamoDB table $TableName"
            } else {
                Write-LzAwsVerbose "Creating DynamoDB table $TableName"
                try {
                    Create-DynamoDbTable -TableName $TableName
                }
                catch {
                    Write-Host "Error: Failed to create DynamoDB table '$TableName' for tenant '$TenantKey'"
                    Write-Host "Hints:"
                    Write-Host "  - Check if you have sufficient AWS permissions"
                    Write-Host "  - Verify the table name is unique in your AWS account"
                    Write-Host "  - Ensure the region is valid and accessible"
                    Write-Error "Failed to create DynamoDB table '$TableName' for tenant '$TenantKey': $($_.Exception.Message)" -ErrorAction Stop
                }
            }

            # Update KVS entry
            Write-LzAwsVerbose "Creating/Updating KVS entry for: $Domain"
            $KvsEntryJson = $KvsEntry | ConvertTo-Json -Depth 10 -Compress
            Write-LzAwsVerbose ("Entry Length: " + $KvsEntryJson.Length)
            if($ReportOnly) {
                Write-Host "Creating KVS entry for: $Domain"
                Write-Host ($KvsEntryJson | ConvertFrom-Json -Depth 10)
            } else {
                try {
                    Update-KVSEntry -KvsARN $KvsArn -Key $Domain -Value $KvsEntryJson
                }
                catch {
                    Write-Host "Error: Failed to update KVS entry for domain '$Domain' in tenant '$TenantKey'"
                    Write-Host "Hints:"
                    Write-Host "  - Check if you have sufficient AWS permissions"
                    Write-Host "  - Verify the KVS ARN is valid"
                    Write-Error "Failed to update KVS entry for domain '$Domain' in tenant '$TenantKey': $($_.Exception.Message)" -ErrorAction Stop
                }
            }
        }

        Write-LzAwsVerbose "Finished deploying tenant resources for $TenantKey"
    }
    catch {
        Write-Error "Failed to deploy tenant resources: $($_.Exception.Message)" -ErrorAction Stop
    }
}