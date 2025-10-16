# KVS Entry Chunking Strategy

## Overview

CloudFront Key-Value Store (KVS) has a limit of 1024 bytes per entry value. When tenant or subtenant configurations exceed this limit, the system automatically splits them into multiple chunks.

## Chunking Strategy

### Entry Keys
- **Primary entry**: Uses the domain as the key (e.g., `example.com`)
- **Overflow entries**: Append `-N` suffix (e.g., `example.com-1`, `example.com-2`, etc.)

### Entry Structure

**Primary Entry (when chunking is needed):**
```json
{
  "systemKey": "mysystem",
  "tenantKey": "tenant1",
  "ss": "abc123",
  "ts": "{ss}",
  "env": "prod",
  "region": "us-east-1",
  "behaviors": [
    // Partial behaviors array
  ],
  "more": "example.com-1"  // Key of next chunk
}
```

**Continuation Entry:**
```json
{
  "systemKey": "mysystem",
  "tenantKey": "tenant1",
  "ss": "abc123",
  "ts": "{ss}",
  "env": "prod",
  "region": "us-east-1",
  "behaviors": [
    // More behaviors
  ],
  "more": "example.com-2"  // Key of next chunk (if any)
}
```

**Final Entry:**
```json
{
  "systemKey": "mysystem",
  "tenantKey": "tenant1",
  "ss": "abc123",
  "ts": "{ss}",
  "env": "prod",
  "region": "us-east-1",
  "behaviors": [
    // Remaining behaviors
  ]
  // No "more" property - this is the last chunk
}
```

## Implementation Details

### PowerShell Module

The `Split-KVSEntry` function in `/Private/Split-KVSEntry.ps1` handles chunking:

1. **Check size**: Convert entry to JSON and measure bytes
2. **If <= 1024 bytes**: Return as-is
3. **If > 1024 bytes**:
   - Extract base metadata (systemKey, tenantKey, etc.)
   - Split behaviors array across multiple entries
   - Add "more" property to link chunks (except final chunk)
   - Validate each chunk is <= 1024 bytes

### CloudFront Function (JavaScript)

To retrieve a chunked entry from CloudFront Functions:

```javascript
async function getFullKVSEntry(kvsHandle, domain) {
    var fullBehaviors = [];
    var baseEntry = null;
    var currentKey = domain;

    // Follow the chain of "more" properties
    while (currentKey) {
        var entry = await kvsHandle.get(currentKey);
        if (!entry) {
            break;
        }

        var entryObj = JSON.parse(entry.value);

        // Save base metadata from first entry
        if (!baseEntry) {
            baseEntry = {
                systemKey: entryObj.systemKey,
                tenantKey: entryObj.tenantKey,
                subtenantKey: entryObj.subtenantKey,
                ss: entryObj.ss,
                ts: entryObj.ts,
                sts: entryObj.sts,
                env: entryObj.env,
                region: entryObj.region
            };
        }

        // Accumulate behaviors
        if (entryObj.behaviors) {
            fullBehaviors = fullBehaviors.concat(entryObj.behaviors);
        }

        // Check for next chunk
        currentKey = entryObj.more || null;
    }

    // Return reconstructed entry
    if (baseEntry) {
        baseEntry.behaviors = fullBehaviors;
        return baseEntry;
    }

    return null;
}

// Usage in CloudFront Function
async function handler(event) {
    var kvsHandle = event.context.kvs;
    var domain = extractDomain(event.request);

    var fullEntry = await getFullKVSEntry(kvsHandle, domain);

    if (fullEntry) {
        // Process behaviors as normal
        var behavior = matchBehavior(event.request.uri, fullEntry.behaviors);
        // ... route request
    }
}
```

## Automatic Handling

The PowerShell deployment functions automatically handle chunked entries:

- **Get-TenantConfig**: Automatically chunks entries that exceed 1024 bytes
- **Deploy-TenantResourcesAws**: Processes all chunks (recognizes `-N` suffix pattern)
- **Remove-KVSChunks**: Cleans up old chunks before writing new ones (prevents orphans)
- **Update-KVSEntry**: Writes each chunk as a separate KVS entry

### Orphan Prevention

To prevent orphaned chunks when updating from a large entry to a smaller one:

1. **Before update**: `yada.com` (100 behaviors) → `yada.com`, `yada.com-1`, `yada.com-2`
2. **New deployment**: `yada.com` (10 behaviors) → only needs `yada.com`
3. **Cleanup**: `Remove-KVSChunks` deletes all old chunks (`yada.com`, `yada.com-1`, `yada.com-2`)
4. **Write new**: Only `yada.com` is written

This ensures no orphaned chunks are left in the KVS.

No special action is required for standard deployments.

## Limitations

- Individual behaviors cannot exceed available space within a chunk
- If base metadata alone exceeds ~950 bytes, chunking will fail
- Maximum practical chunks: unlimited (but consider performance impact)

## Troubleshooting

### Error: "Base metadata too large to fit in 1024 byte limit"
**Solution**: Reduce the size of:
- Domain names (use shorter domains)
- System/tenant/subtenant keys
- Region or environment values

### Error: "Chunk still exceeds 1024 bytes after splitting"
**Solution**: Individual behaviors are too complex. Consider:
- Reducing the number of paths in a single behavior
- Shortening API IDs or other identifiers
- Splitting behaviors into smaller components

### Debugging Chunked Entries
Enable verbose output:
```powershell
Set-LzAwsVerbosity -Preference "Continue"
Deploy-TenantAws -TenantKey "mytenant"
```

This will show:
- Chunk creation process
- Size of each chunk in bytes
- Number of behaviors per chunk
