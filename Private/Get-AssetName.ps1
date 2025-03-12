function Get-AssetName($KvsEntry, $Behavior, $IncludeAwsSuffix = $true) {
    # Extract values from KVS entry
    $SystemKey = $KvsEntry.systemKey
    $TenantKey = $KvsEntry.tenantKey
    $SubtenantKey = $KvsEntry.subtenantKey
    $Ss = $KvsEntry.ss
    $Ts = $KvsEntry.ts
    $Sts = $KvsEntry.sts
    
    $AssetType = $Behavior[1]
    $AwsSuffix = '.amazonaws.com'

    $BehaviorString = $Behavior -join ", "
    Write-LzAwsVerbose "behavior: $BehaviorString"

    switch($AssetType) {
        "api" {
            # behavior array:
            # [0] path
            # [1] assetType
            # [2] apiName 
            # [3] region
            # [4] level
            # Maps to: [apiName].execute-api.[region].amazonaws.com
            $AssetName = $Behavior[2] 
            if($IncludeAwsSuffix -eq $true) {
                 $AssetName += '.execute-api.' + $Behavior[3] + $AwsSuffix
            }
        }
        "assets" {
            # behavior array:
            # [0] path
            # [1] assetType
            # [2] suffix
            # [3] region
            # [4] level
            # Maps to: [systemKey]-[tenantKey]-[subtenantKey]-[assetType]-[suffix].s3.[region].amazonaws.com
            $BehaviorLevel = $Behavior[4]
            $AssetTenantKey = $(if($BehaviorLevel -gt 0) {$TenantKey} else {''})
            $AssetSubtenantKey = $(if($BehaviorLevel -gt 1) {$SubtenantKey} else {''}) 
            $AssetName = $SystemKey + "-" + $AssetTenantKey + "-" + $AssetSubtenantKey + "-" + $AssetType + "-" + $Behavior[2] 
            if($IncludeAwsSuffix -eq $true) {
                $AssetName += '.s3.' + $Behavior[3] + $AwsSuffix
            }
        }
            
        "webapp" {
            # behavior array:
            # [0] path
            # [1] assetType
            # [2] appName
            # [3] suffix
            # [4] region
            # [5] level
            # Maps to: [systemKey]-[tenantKey]-[subtenantKey]-[assetType]-[appName]-[suffix].s3.[region].amazonaws.com
            $BehaviorLevel = $Behavior[5]
            $AssetTenantKey = $(if($BehaviorLevel -gt 0) {$TenantKey} else {''})
            $AssetSubtenantKey = $(if($BehaviorLevel -gt 1) {$SubtenantKey} else {''}) 
            $AssetName = $SystemKey + "-" + $AssetTenantKey + "-" + $AssetSubtenantKey + "-" + $AssetType + "-" + $Behavior[2] + "-" + $Behavior[3] 
            if($IncludeAwsSuffix -eq $true) {
                $AssetName += '.s3.' + $Behavior[4] + $AwsSuffix
            }
        }
    }

    # Replace tokens in order since $sts may contain "{ts}" and $ts may contain "{ss}"
    $AssetName = $AssetName -replace "{sts}", $Sts
    $AssetName = $AssetName -replace "{ts}", $Ts
    $AssetName = $AssetName -replace "{ss}", $Ss    
 
    return $AssetName
}