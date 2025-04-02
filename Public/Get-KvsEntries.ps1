<#
.SYNOPSIS
    Reads the KVS entries for the current account
.DESCRIPTION
    Reads the KVS entries for the current account
.EXAMPLE
    Get-KvsEntries
.EXAMPLE
    Get-KvsEntries
.NOTES
    Requires valid AWS credentials and appropriate permissions
    Must be run in the webapp Solution root folder
.OUTPUTS
    None
#>
function Get-KvsEntries {

    try {
        Get-SystemConfig # sets script scopevariables
        $Region = $script:Region
        $Account = $script:Account    
        $ProfileName = $script:ProfileName
        $Config = $script:Config

        Write-LzAwsVerbose "Region: $Region, Account: $Account"
   
        $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---system")
        $KvsArn = $ServiceStackOutputDict["KeyValueStoreArn"]

        # Retrieve the entire response object
        $null = Get-CFKVKeyValueStore -KvsARN $KvsARN

        $Response = Get-CFKVKeyList -KvsARN $KvsARN

        return $Response
    }
    catch {
        Write-LzAwsVerbose "Error connecting to CloudFront KVS"
        throw
    }    
}