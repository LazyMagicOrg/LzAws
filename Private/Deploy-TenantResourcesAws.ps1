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
            Write-Error "The tenant key $TenantKey is not defined in the SystemConfig.yaml file."
            return
        }

        # Get tenant config and KVS ARN
        $KvsEntriesJson = Get-TenantConfig $TenantKey 
        $KvsEntries = ConvertFrom-Json $KvsEntriesJson -Depth 10

        $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---system")
        $KvsArn = $ServiceStackOutputDict["KeyValueStoreArn"]

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
                    New-LzAwsS3Bucket -BucketName $AssetName -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName
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
                Create-DynamoDbTable -TableName $TableName
            }

            # Update KVS entry
            Write-LzAwsVerbose "Creating/Updating KVS entry for: $Domain"
            $KvsEntryJson = $KvsEntry | ConvertTo-Json -Depth 10 -Compress
            Write-LzAwsVerbose ("Entry Length: " + $KvsEntryJson.Length)
            if($ReportOnly) {
                Write-Host "Creating KVS entry for: $Domain"
                Write-Host ($KvsEntryJson | ConvertFrom-Json -Depth 10)
            } else {
                Update-KVSEntry -KvsARN $KvsArn -Key $Domain -Value $KvsEntryJson
            }
        }

        Write-LzAwsVerbose "Finished deploying tenant assets for tenant $TenantKey"
    }
    catch {
        Write-Error "Failed to deploy tenant resources: $($_.Exception.Message)"
        throw
    }
}