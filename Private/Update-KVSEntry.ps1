function Update-KVSEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$KvsARN,
        [Parameter(Mandatory=$true)]
        [string]$Key,
        [Parameter(Mandatory=$true)]
        [string]$KvsEntryJson
    )

    $Region = $script:Region
    $ProfileName = $script:ProfileName

    if ($null -eq $KvsARN -or $null -eq $Key -or $null -eq $KvsEntry) {
        $errorMessage = @"
Error: Required parameters are missing
Function: Update-KVSEntry
Hints:
- KvsARN: $KvsARN
- Key: $Key
"@
        throw $errorMessage
    }

    try {
        # Retrieve the entire response object
        $Response = Get-CFKVKeyValueStore -KvsARN $KvsARN -ProfileName $ProfileName -Region $Region
    } catch {
        $errorMessage = @"
Error: Failed to retrieve KVSKeyValueStore
Function: Update-KVSEntry
Hints:
- Check if the KVS exists
- Ensure you have sufficient AWS permissions
"@
        throw $errorMessage
    }
        
    # Extract just the ETag from the response
    $ETag = $Response.ETag

    try {
        # Pass that ETag to IfMatch
        $Response = Write-CFKVKey -KvsARN $KvsARN -Key $Key -Value $KvsEntryJson -IfMatch $ETag -ProfileName $ProfileName -Region $Region
    } catch {
        $errorMessage = @"
Error: Failed to update KVS entry for key '$Key'
Function: Update-KVSEntry
Hints:
- Check if the KVS exists
- Ensure you have sufficient AWS permissions
"@
        throw $errorMessage
    }   

    Write-LzAwsVerbose "Successfully updated KVS entry for key '$Key'"

}
