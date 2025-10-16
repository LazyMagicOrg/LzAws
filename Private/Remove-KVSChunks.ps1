# Removes all chunks for a given domain key (domain, domain-1, domain-2, etc.)
# This prevents orphaned chunks when updating from a large entry to a smaller one

function Remove-KVSChunks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$KvsARN,

        [Parameter(Mandatory=$true)]
        [string]$Domain
    )

    $Region = $script:Region
    $ProfileName = $script:ProfileName

    Write-LzAwsVerbose "Removing existing chunks for domain '$Domain'"

    try {
        # Get ETag for the KVS
        $Response = Get-CFKVKeyValueStore -KvsARN $KvsARN -ProfileName $ProfileName -Region $Region
        $ETag = $Response.ETag

        # Build list of potential chunk keys to delete
        # Since we can't list all keys, try deleting domain and domain-1 through domain-10
        # This is a reasonable upper limit for chunks
        $ChunksToDelete = @()
        $ChunksToDelete += $Domain  # Primary key

        # Add potential chunk keys (domain-1 through domain-10)
        for ($i = 1; $i -le 10; $i++) {
            $ChunksToDelete += "$Domain-$i"
        }

        if ($ChunksToDelete.Count -eq 0) {
            Write-LzAwsVerbose "No chunks found to delete for '$Domain'"
            return
        }

        Write-LzAwsVerbose "Attempting to delete up to $($ChunksToDelete.Count) potential chunk(s)"

        # Delete each chunk (silently skip non-existent keys)
        foreach ($ChunkKey in $ChunksToDelete) {
            try {
                Write-LzAwsVerbose "Attempting to delete chunk: $ChunkKey"
                Remove-CFKVSKey -KvsARN $KvsARN -Key $ChunkKey -IfMatch $ETag -ProfileName $ProfileName -Region $Region
                Write-LzAwsVerbose "Successfully deleted chunk: $ChunkKey"
            } catch {
                # Key might not exist, which is fine - fail silently
                Write-LzAwsVerbose "Chunk '$ChunkKey' does not exist or could not be deleted, skipping"
            }
        }

        Write-LzAwsVerbose "Cleanup complete for domain '$Domain'"

    } catch {
        $errorMessage = @"
Error: Failed to cleanup chunks for domain '$Domain'
Function: Remove-KVSChunks
Hints:
- Check if the KVS exists
- Ensure you have sufficient AWS permissions
- Verify the KVS ARN is correct

Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
    }
}
