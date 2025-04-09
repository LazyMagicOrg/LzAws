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

    $ProfileName = $script:ProfileName
    $Region = $script:Region
    $Account = $script:Account
    $Config = $script:Config

    if ($null -eq $Config) {
        $errorMessage = @"
Error: System configuration is required
Function: Deploy-TenantResourcesAws
Hints:
  - Check if systemconfig.yaml is loaded
  - Verify the configuration is not null
  - Ensure the configuration file exists
  - Review the configuration loading process
"@
        throw $errorMessage
    }

    if ($null -eq $Region -or $null -eq $Account -or $null -eq $ProfileName) {
        $errorMessage = @"
Error: Required AWS configuration is missing
Function: Deploy-TenantResourcesAws
Hints:
  - Check if AWS region is set
  - Verify AWS account is configured
  - Ensure AWS profile name is set
  - Review AWS configuration settings
"@
        throw $errorMessage
    }
   
    # Validate tenant exists in config
    if(-not $Config.Tenants.ContainsKey($TenantKey)) {
        $errorMessage = @"
Error: Tenant '$TenantKey' not found in configuration
Function: Deploy-TenantResourcesAws
Hints:
  - Check if the tenant key is correct
  - Verify the tenant is defined in systemconfig.yaml
  - Ensure you're using the correct system configuration
  - Review the tenant configuration structure
"@
        throw $errorMessage
    }

    # Get tenant config and KVS ARN

    $KvsEntriesJson = Get-TenantConfig $TenantKey 

    try {
        $KvsEntries = ConvertFrom-Json $KvsEntriesJson -Depth 10
    }
    catch {
        $errorMessage = @"
Error: Failed to convert KvsEntries for '$TenantKey'
Function: Deploy-TenantResourcesAws
Hints:
  - Ensure the KeyValueStore is properly configured
  - Review the tenant configuration format
"@
        throw $errorMessage
    }

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
            Update-KVSEntry -KvsARN $KvsArn -Key $Domain -KvsEntryJson $KvsEntryJson
        }
    }

    Write-LzAwsVerbose "Finished deploying tenant resources for $TenantKey"
}