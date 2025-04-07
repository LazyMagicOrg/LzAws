function Update-KVSEntry {
    param (
        [Parameter(Mandatory = $true)]
        [string]$KvsARN,
        
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    try {
        # Retrieve the entire response object
        try {
            $Response = Get-CFKVKeyValueStore -KvsARN $KvsARN
        }
        catch {
            Write-Host "Error: Failed to retrieve KVS store for ARN '$KvsARN'"
            Write-Host "Hints:"
            Write-Host "  - Check if the KVS ARN is valid"
            Write-Host "  - Verify you have sufficient AWS permissions"
            Write-Host "  - Ensure the KVS store exists and is accessible"
            Write-Host "AWS Error: $($_.Exception.Message)"
            Write-Error "Failed to retrieve KVS store for ARN '$KvsARN': $($_.Exception.Message)" -ErrorAction Stop
        }
        
        # Extract just the ETag from the response
        $ETag = $Response.ETag

        # Pass that ETag to IfMatch
        try {
            $Response = Write-CFKVKey -KvsARN $KvsARN -Key $Key -Value $Value -IfMatch $ETag
            Write-LzAwsVerbose "Successfully updated KVS entry for key: $Key"
            return $Response
        }
        catch {
            Write-Host "Error: Failed to update KVS entry for key '$Key'"
            Write-Host "Hints:"
            Write-Host "  - Check if the KVS store is accessible"
            Write-Host "  - Verify the key and value are valid"
            Write-Host "AWS Error: $($_.Exception.Message)"
            Write-Error "Failed to update KVS entry for key '$Key': $($_.Exception.Message)" -ErrorAction Stop
        }
    }
    catch {
        Write-Host "Error: An unexpected error occurred while updating KVS entry"
        Write-Host "Hints:"
        Write-Host "  - Check AWS service status"
        Write-Host "  - Verify all required parameters are valid"
        Write-Host "  - Review AWS CloudTrail logs for details"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "An unexpected error occurred while updating KVS entry: $($_.Exception.Message)" -ErrorAction Stop
    }
}
