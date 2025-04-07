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

        $SystemConfig = Get-SystemConfig
        # Get-SystemConfig already handles exit 1 on failure

        $Region = $SystemConfig.Region
        $Account = $SystemConfig.Account      
        $Config = $SystemConfig.Config
        $ProfileName = $SystemConfig.ProfileName

        Write-LzAwsVerbose "Region: $Region, Account: $Account"
        
        try {
            $ServiceStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---system")
            $KvsArn = $ServiceStackOutputDict["KeyValueStoreArn"]
            if (-not $KvsArn) {
                Write-Host "Error: KeyValueStoreArn not found in stack outputs"
                Write-Host "Hints:"
                Write-Host "  - Check if the system stack is properly deployed"
                Write-Host "  - Verify the stack outputs contain KeyValueStoreArn"
                Write-Host "  - Ensure you have permission to read stack outputs"
                exit 1
            }
        }
        catch {
            Write-Host "Error: Failed to get stack outputs"
            Write-Host "Hints:"
            Write-Host "  - Check if the system stack exists"
            Write-Host "  - Verify AWS credentials are valid"
            Write-Host "  - Ensure you have permission to read stack outputs"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        try {
            # Retrieve the entire response object
            Get-CFKVKeyValueStore -KvsARN $KvsARN
            $Response = Get-CFKVKeyList -KvsARN $KvsARN
            return $Response
        }
        catch {
            Write-Host "Error: Failed to retrieve KVS entries"
            Write-Host "Hints:"
            Write-Host "  - Check if the KVS service is available"
            Write-Host "  - Verify the KVS ARN is valid"
            Write-Host "  - Ensure you have permission to access KVS"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
    }
    catch {
        Write-Host "Error: An unexpected error occurred while retrieving KVS entries"
        Write-Host "Hints:"
        Write-Host "  - Check AWS service availability"
        Write-Host "  - Verify AWS credentials are valid"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}