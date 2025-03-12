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

    $SystemConfig = Get-SystemConfig 
    $Region = $SystemConfig.Region
    $Account = $SystemConfig.Account
    $Config = $SystemConfig.Config
    $ProfileName = $SystemConfig.ProfileName

    Write-LzAwsVerbose "Region: $Region, Account: $Account"
    
   
    $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---system")
    $KvsArn = $ServiceStackOutputDict["KeyValueStoreArn"]

    try {
        # Retrieve the entire response object
        Get-CFKVKeyValueStore -KvsARN $KvsARN

        $Response = Get-CFKVKeyList -KvsARN $KvsARN

        return $Response
    }
    catch {
        Write-LzAwsVerbose "Error connecting to CloudFront KVS"
        throw
    }    
}