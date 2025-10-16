# Test script for KVS chunking functionality
# This script tests the Split-KVSEntry function with various scenarios

# Import the module
Import-Module "$PSScriptRoot/../LzAws.psd1" -Force

Write-Host "Testing KVS Chunking Functionality" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan
Write-Host ""

# Test 1: Entry that doesn't need chunking
Write-Host "Test 1: Small entry (no chunking needed)" -ForegroundColor Yellow
$SmallEntry = @{
    systemKey = "test"
    tenantKey = "tenant1"
    ss = "abc123"
    ts = "{ss}"
    env = "dev"
    region = "us-east-1"
    behaviors = @(
        @("/api/", "api", "xyz789", "us-east-1", "dev"),
        @("/", "webapp", "app1", "{ss}", "us-east-1", 0)
    )
}

try {
    $Result1 = Split-KVSEntry -Domain "small.example.com" -KvsEntry $SmallEntry
    Write-Host "✓ Success: $($Result1.Count) chunk(s) created" -ForegroundColor Green
    foreach ($Key in $Result1.Keys) {
        $Json = $Result1[$Key] | ConvertTo-Json -Depth 10 -Compress
        $Size = [System.Text.Encoding]::UTF8.GetByteCount($Json)
        Write-Host "  - Key: $Key, Size: $Size bytes" -ForegroundColor Gray
    }
} catch {
    Write-Host "✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 2: Entry that needs chunking (create large behavior array)
Write-Host "Test 2: Large entry (chunking required)" -ForegroundColor Yellow
$LargeBehaviors = @()
for ($i = 0; $i -lt 50; $i++) {
    $LargeBehaviors += ,@("/path$i/", "assets", "{ss}", "us-east-1", 1)
    $LargeBehaviors += ,@("/api$i/", "api", "apiid$i" + "x" * 20, "us-east-1", "dev")
}

$LargeEntry = @{
    systemKey = "test"
    tenantKey = "tenant1"
    ss = "abc123"
    ts = "{ss}"
    env = "dev"
    region = "us-east-1"
    behaviors = $LargeBehaviors
}

try {
    $Result2 = Split-KVSEntry -Domain "large.example.com" -KvsEntry $LargeEntry
    Write-Host "✓ Success: $($Result2.Count) chunk(s) created" -ForegroundColor Green

    $ChunkIndex = 0
    foreach ($Key in ($Result2.Keys | Sort-Object)) {
        $Json = $Result2[$Key] | ConvertTo-Json -Depth 10 -Compress
        $Size = [System.Text.Encoding]::UTF8.GetByteCount($Json)
        $BehaviorCount = $Result2[$Key].behaviors.Count
        $HasMore = $Result2[$Key].ContainsKey('more')
        Write-Host "  - Key: $Key" -ForegroundColor Gray
        Write-Host "    Size: $Size bytes, Behaviors: $BehaviorCount, Has 'more': $HasMore" -ForegroundColor Gray

        # Validate size
        if ($Size -gt 1024) {
            Write-Host "    ✗ ERROR: Chunk exceeds 1024 bytes!" -ForegroundColor Red
        }

        # Validate "more" property chain
        if ($HasMore) {
            $ExpectedNext = if ($ChunkIndex -eq 0) { "large.example.com-1" } else { "large.example.com-$($ChunkIndex + 1)" }
            if ($Result2[$Key].more -ne $ExpectedNext) {
                Write-Host "    ✗ ERROR: 'more' property incorrect. Expected: $ExpectedNext, Got: $($Result2[$Key].more)" -ForegroundColor Red
            }
        }

        $ChunkIndex++
    }
} catch {
    Write-Host "✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 3: Subtenant entry
Write-Host "Test 3: Subtenant entry with moderate behaviors" -ForegroundColor Yellow
$SubtenantBehaviors = @()
for ($i = 0; $i -lt 20; $i++) {
    $SubtenantBehaviors += ,@("/store$i/", "webapp", "storeapp$i", "{sts}", "us-west-2", 2)
}

$SubtenantEntry = @{
    systemKey = "test"
    tenantKey = "tenant1"
    subtenantKey = "store1"
    ss = "abc123"
    ts = "{ss}"
    sts = "xyz789"
    env = "prod"
    region = "us-west-2"
    behaviors = $SubtenantBehaviors
}

try {
    $Result3 = Split-KVSEntry -Domain "store1.example.com" -KvsEntry $SubtenantEntry
    Write-Host "✓ Success: $($Result3.Count) chunk(s) created" -ForegroundColor Green
    foreach ($Key in $Result3.Keys) {
        $Json = $Result3[$Key] | ConvertTo-Json -Depth 10 -Compress
        $Size = [System.Text.Encoding]::UTF8.GetByteCount($Json)
        Write-Host "  - Key: $Key, Size: $Size bytes" -ForegroundColor Gray
    }
} catch {
    Write-Host "✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 4: Reconstruct behaviors from chunks
Write-Host "Test 4: Verify behavior reconstruction" -ForegroundColor Yellow
try {
    # Use the large entry from Test 2
    $ReconstructedBehaviors = @()
    $CurrentKey = "large.example.com"

    while ($CurrentKey -and $Result2.ContainsKey($CurrentKey)) {
        $Chunk = $Result2[$CurrentKey]
        $ReconstructedBehaviors += $Chunk.behaviors
        $CurrentKey = $Chunk.more
    }

    $OriginalCount = $LargeEntry.behaviors.Count
    $ReconstructedCount = $ReconstructedBehaviors.Count

    if ($OriginalCount -eq $ReconstructedCount) {
        Write-Host "✓ Success: All behaviors preserved ($ReconstructedCount behaviors)" -ForegroundColor Green
    } else {
        Write-Host "✗ Failed: Behavior count mismatch. Original: $OriginalCount, Reconstructed: $ReconstructedCount" -ForegroundColor Red
    }
} catch {
    Write-Host "✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Summary
Write-Host "===================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "All tests completed. Review output above for any errors." -ForegroundColor Gray
