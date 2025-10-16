# Splits a KVS entry into multiple chunks if it exceeds 1024 bytes
# Returns a hashtable where keys are the domain (and domain-1, domain-2, etc.)
# and values are the chunked entry objects
#
# Strategy:
# - If entry <= 1024 bytes: return as-is
# - If entry > 1024 bytes: split behaviors across multiple entries
#   - First entry gets base metadata + partial behaviors + "more" property
#   - Subsequent entries get remaining behaviors + "more" property (if needed)
#   - Last entry has no "more" property

function Split-KVSEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Domain,

        [Parameter(Mandatory=$true)]
        [hashtable]$KvsEntry
    )

    Write-LzAwsVerbose "Checking if KVS entry for '$Domain' needs chunking"

    # First, try the entry as-is
    $KvsEntryJson = $KvsEntry | ConvertTo-Json -Depth 10 -Compress
    $ByteCount = [System.Text.Encoding]::UTF8.GetByteCount($KvsEntryJson)

    Write-LzAwsVerbose "Entry size: $ByteCount bytes"

    if ($ByteCount -le 1024) {
        # No chunking needed
        Write-LzAwsVerbose "No chunking needed for '$Domain'"
        return @{ $Domain = $KvsEntry }
    }

    Write-LzAwsVerbose "Chunking required for '$Domain' (size: $ByteCount bytes)"

    # Extract behaviors and metadata
    $Behaviors = $KvsEntry.behaviors
    if ($null -eq $Behaviors -or $Behaviors.Count -eq 0) {
        $errorMessage = @"
Error: KVS entry exceeds 1024 bytes but has no behaviors to split
Function: Split-KVSEntry
Hints:
  - The entry metadata alone is too large
  - Consider reducing the size of domain, keys, or other metadata
  - Entry size: $ByteCount bytes
"@
        throw $errorMessage
    }

    # Create base metadata (everything except behaviors)
    $BaseMeta = @{
        systemKey = $KvsEntry.systemKey
        tenantKey = $KvsEntry.tenantKey
        env = $KvsEntry.env
        region = $KvsEntry.region
        ss = $KvsEntry.ss
        ts = $KvsEntry.ts
    }

    # Add optional properties if they exist
    if ($KvsEntry.ContainsKey('subtenantKey')) {
        $BaseMeta.subtenantKey = $KvsEntry.subtenantKey
    }
    if ($KvsEntry.ContainsKey('sts')) {
        $BaseMeta.sts = $KvsEntry.sts
    }

    # Calculate base metadata size
    $BaseMetaJson = $BaseMeta | ConvertTo-Json -Depth 10 -Compress
    $BaseMetaSize = [System.Text.Encoding]::UTF8.GetByteCount($BaseMetaJson)

    # Account for "behaviors":[] wrapper and "more":"domain-N" property
    # Estimate: "behaviors":[] = 14 bytes, "more":"domain-999" = ~25 bytes
    $OverheadSize = 50  # Conservative estimate for JSON structure overhead
    $MorePropertySize = $Domain.Length + 20  # "more":"domain-N"

    $AvailableForBehaviors = 1024 - $BaseMetaSize - $OverheadSize - $MorePropertySize

    Write-LzAwsVerbose "Base metadata size: $BaseMetaSize bytes, Available for behaviors: $AvailableForBehaviors bytes"

    if ($AvailableForBehaviors -le 0) {
        $errorMessage = @"
Error: Base metadata too large to fit in 1024 byte limit
Function: Split-KVSEntry
Hints:
  - Base metadata size: $BaseMetaSize bytes
  - Maximum allowed: ~950 bytes to leave room for behaviors
  - Consider using shorter domain names or key values
"@
        throw $errorMessage
    }

    # Split behaviors into chunks
    $ChunkedEntries = @{}
    $ChunkIndex = 0
    $CurrentBehaviors = @()
    $CurrentSize = $BaseMetaSize + $OverheadSize

    foreach ($Behavior in $Behaviors) {
        # Calculate size of this behavior
        $BehaviorJson = $Behavior | ConvertTo-Json -Depth 10 -Compress
        $BehaviorSize = [System.Text.Encoding]::UTF8.GetByteCount($BehaviorJson) + 1  # +1 for comma

        # Check if adding this behavior would exceed limit
        $ProjectedSize = $CurrentSize + $BehaviorSize
        if ($ChunkIndex -gt 0 -or $CurrentBehaviors.Count -gt 0) {
            $ProjectedSize += $MorePropertySize  # Account for "more" property
        }

        if ($ProjectedSize -gt 1024 -and $CurrentBehaviors.Count -gt 0) {
            # Save current chunk and start new one
            $ChunkKey = if ($ChunkIndex -eq 0) { $Domain } else { "$Domain-$ChunkIndex" }
            $NextChunkKey = "$Domain-$($ChunkIndex + 1)"

            $ChunkEntry = $BaseMeta.Clone()
            $ChunkEntry.behaviors = $CurrentBehaviors
            $ChunkEntry.more = $NextChunkKey

            $ChunkedEntries[$ChunkKey] = $ChunkEntry

            Write-LzAwsVerbose "Created chunk '$ChunkKey' with $($CurrentBehaviors.Count) behaviors"

            # Start new chunk
            $ChunkIndex++
            $CurrentBehaviors = @($Behavior)
            $CurrentSize = $BaseMetaSize + $OverheadSize + $BehaviorSize
        }
        else {
            # Add behavior to current chunk
            $CurrentBehaviors += ,$Behavior
            $CurrentSize += $BehaviorSize
        }
    }

    # Save final chunk (no "more" property)
    $FinalChunkKey = if ($ChunkIndex -eq 0) { $Domain } else { "$Domain-$ChunkIndex" }
    $FinalChunkEntry = $BaseMeta.Clone()
    $FinalChunkEntry.behaviors = $CurrentBehaviors

    $ChunkedEntries[$FinalChunkKey] = $FinalChunkEntry

    Write-LzAwsVerbose "Created final chunk '$FinalChunkKey' with $($CurrentBehaviors.Count) behaviors"
    Write-LzAwsVerbose "Total chunks created: $($ChunkedEntries.Count)"

    # Validate all chunks are under 1024 bytes
    foreach ($ChunkKey in $ChunkedEntries.Keys) {
        $ChunkJson = $ChunkedEntries[$ChunkKey] | ConvertTo-Json -Depth 10 -Compress
        $ChunkByteCount = [System.Text.Encoding]::UTF8.GetByteCount($ChunkJson)

        if ($ChunkByteCount -gt 1024) {
            $errorMessage = @"
Error: Chunk '$ChunkKey' still exceeds 1024 bytes after splitting
Function: Split-KVSEntry
Hints:
  - Chunk size: $ChunkByteCount bytes
  - Individual behaviors may be too large
  - Consider reducing behavior complexity or metadata size
  - Review behavior array structure
"@
            throw $errorMessage
        }

        Write-LzAwsVerbose "Chunk '$ChunkKey' validated: $ChunkByteCount bytes"
    }

    return $ChunkedEntries
}
