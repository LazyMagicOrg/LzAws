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
    [CmdletBinding()]
    param()

    try {
        Write-LzAwsVerbose "Starting KVS entries retrieval"

        $null = Get-SystemConfig
        $Region = $script:Region
        $Account = $script:Account      
        $Config = $script:Config
        $ProfileName = $script:ProfileName

       
        $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---system")
        $KvsArn = $ServiceStackOutputDict["KeyValueStoreArn"]
        if (-not $KvsArn) {
            $errorMessage = @"
Error: KeyValueStoreArn not found in stack outputs
Function: Get-KvsEntries
Hints:
  - Check if the system stack is properly deployed
  - Verify the stack outputs contain KeyValueStoreArn
  - Ensure you have permission to read stack outputs
"@
            throw $errorMessage
        }

        # Retrieve the entire response object
        Get-CFKVKeyValueStore -KvsARN $KvsARN
        $Response = Get-CFKVKeyList -KvsARN $KvsARN
        return $Response
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
}