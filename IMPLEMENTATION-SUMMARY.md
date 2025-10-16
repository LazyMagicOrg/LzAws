# KVS Chunking Implementation Summary

## Overview
Implemented automatic chunking of CloudFront Key-Value Store (KVS) entries that exceed the 1024-byte limit. The solution transparently splits large tenant/subtenant configurations across multiple KVS entries.

## Files Created

### 1. `/Private/Split-KVSEntry.ps1`
**Purpose**: Core chunking logic

**Key Features**:
- Automatically detects entries exceeding 1024 bytes
- Splits behaviors array across multiple chunks
- Maintains base metadata (systemKey, tenantKey, etc.) in each chunk
- Creates chain of entries using "more" property
- Validates each chunk is under 1024 bytes

### 2. `/Private/Remove-KVSChunks.ps1`
**Purpose**: Cleanup orphaned chunks before updates

**Key Features**:
- Removes all existing chunks for a domain (domain, domain-1, domain-2, etc.)
- Prevents orphaned entries when updating from large to small configurations
- Lists all KVS keys and finds matching chunk patterns
- Gracefully handles non-existent keys

**Algorithm**:
1. Calculate base metadata size
2. Iteratively add behaviors until approaching 1024-byte limit
3. Create new chunk when threshold reached
4. Link chunks via "more" property pointing to next key
5. Final chunk has no "more" property

### 3. `/Tests/Test-KVSChunking.ps1`
**Purpose**: Test script for validation

**Test Cases**:
- Small entry (no chunking needed)
- Large entry (requires multiple chunks)
- Subtenant entry with moderate behaviors
- Behavior reconstruction from chunks

**Usage**:
```powershell
.\Tests\Test-KVSChunking.ps1
```

### 4. `/KVS-CHUNKING.md`
**Purpose**: Complete documentation

**Contents**:
- Chunking strategy explanation
- Entry structure examples
- PowerShell implementation details
- CloudFront Function code for consuming chunks
- Troubleshooting guide

## Files Modified

### 1. `/Private/Get-TenantConfig.ps1`
**Changes**:
- Lines 101-108: Apply `Split-KVSEntry` to tenant entries
- Lines 125-132: Apply `Split-KVSEntry` to subtenant entries

**Impact**: Automatically chunks all tenant/subtenant entries during generation

### 2. `/Private/Deploy-TenantResourcesAws.ps1`
**Changes**:
- Lines 80-90: Updated comments and added logic to handle chunked entry keys
- Lines 125-128: Added `Remove-KVSChunks` call before updating entries
- Uses regex to strip `-\d+$` suffix from chunked keys when determining domain level

**Impact**:
- Deployment correctly processes all chunks
- Orphaned chunks are cleaned up on every deployment

### 3. `/CLAUDE.md`
**Changes**:
- Lines 130-137: Added "KVS Entry Chunking" section

**Impact**: Documents the feature for future development

## How It Works

### Entry Key Pattern
```
example.com          → Primary entry
example.com-1        → First overflow chunk
example.com-2        → Second overflow chunk
...
example.com-N        → Nth overflow chunk
```

### Entry Structure
**Primary/Continuation Chunks**:
```json
{
  "systemKey": "...",
  "tenantKey": "...",
  "behaviors": [...],
  "more": "example.com-1"  // Next chunk key
}
```

**Final Chunk**:
```json
{
  "systemKey": "...",
  "tenantKey": "...",
  "behaviors": [...]
  // No "more" property
}
```

### CloudFront Function Integration
CloudFront Functions must follow the "more" chain:

```javascript
async function getFullKVSEntry(kvsHandle, domain) {
    var fullBehaviors = [];
    var currentKey = domain;

    while (currentKey) {
        var entry = await kvsHandle.get(currentKey);
        var entryObj = JSON.parse(entry.value);

        fullBehaviors = fullBehaviors.concat(entryObj.behaviors);
        currentKey = entryObj.more || null;
    }

    return { ...baseMetadata, behaviors: fullBehaviors };
}
```

## Deployment Impact

### Transparent Operation
- **Get-TenantConfig**: Automatically chunks during generation
- **Deploy-TenantResourcesAws**: Processes all chunks automatically
- **Remove-KVSChunks**: Cleans up old chunks before update (prevents orphans)
- **Update-KVSEntry**: Writes each chunk as separate KVS entry

### Orphan Prevention
When updating tenant configurations, old chunks are automatically removed:
```
Scenario: yada.com shrinks from 100 to 10 behaviors
Before: yada.com, yada.com-1, yada.com-2 (all exist)
Cleanup: Remove-KVSChunks deletes all three
Write: Only yada.com is recreated
Result: No orphaned yada.com-1 or yada.com-2
```

### No Breaking Changes
- Entries under 1024 bytes work exactly as before
- Chunked entries are backward compatible
- Existing deployments unaffected

## Testing

### Unit Tests
Run the test script:
```powershell
Import-Module ./LzAws.psd1 -Force
.\Tests\Test-KVSChunking.ps1
```

### Integration Testing
1. Create tenant with many behaviors in `systemconfig.yaml`
2. Deploy tenant:
   ```powershell
   Set-LzAwsVerbosity -Preference "Continue"
   Deploy-TenantAws -TenantKey "test-tenant"
   ```
3. Verify in verbose output:
   - Chunk creation messages
   - Size of each chunk
   - "more" property chains

### Validation
Check AWS CloudFront KVS entries:
```powershell
# List all keys for a tenant
aws cloudfront-keyvaluestore list-keys --kvs-arn <arn>

# Get specific chunk
aws cloudfront-keyvaluestore get-key --kvs-arn <arn> --key "example.com-1"
```

## Error Handling

### Errors Thrown
1. **"Base metadata too large"**: Metadata alone exceeds ~950 bytes
2. **"Chunk still exceeds 1024 bytes"**: Individual behavior too large

### Resolution
- Use shorter domain names
- Reduce system/tenant/subtenant key lengths
- Split complex behaviors
- Simplify path patterns

## Next Steps

### CloudFront Function Update
Update your CloudFront Functions to use the chunking retrieval pattern (see KVS-CHUNKING.md)

### Monitoring
Monitor KVS entry sizes during deployments:
```powershell
Set-LzAwsVerbosity -Preference "Continue"
```

### Future Enhancements
- Configurable chunk size threshold
- Compression options
- Automatic behavior optimization
