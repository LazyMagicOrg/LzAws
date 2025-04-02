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
        $ProfileName = $script:ProfileName

        # Retrieve the entire response object
        $Response = Get-CFKVKeyValueStore -KvsARN $KvsARN -ProfileName $ProfileName -Region $Region
        
        # Extract just the ETag from the response
        $ETag = $Response.ETag

        # Pass that ETag to IfMatch
        $Response = Write-CFKVKey -KvsARN $KvsARN -Key $Key -Value $Value -IfMatch $ETag -ProfileName $ProfileName -Region $Region

        Write-LzAwsVerbose "Successfully updated KVS entry for key: $Key"
        return $Response
    }
    catch {
        Write-LzAwsVerbose "Error updating KVS entry: $_"
        throw
    }
}
