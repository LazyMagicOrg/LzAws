# Generate asset names for the tenant or subtenant
# myLevel = 1 for tenant 
# myLevel = 2 for subtenant
# notes: 
# 1. level 0 (system) is always generated
# 2. This logic is similar to that implemented in the CloudFront Function 
#   handling requests. The myTenant object passed contains the same information
#   returned from the kvs for the tenant or subtenant.
function Get-AssetNames($KvsEntry, $Report = $false, $S3Only = $false) {
    $AssetNames = @()   
    $TenantKey = $KvsEntry.tenantKey
    $SubtenantKey = $KvsEntry.subtenantKey

    Write-LzAwsVerbose "Generating asset names for TenantKey: $TenantKey SubtenantKey: $SubtenantKey level: $TenantLevel report: $Report s3only: $S3Only"

    # Match Precedence
    # Each behavior starts with a Path. The path is a comma delimited string containing one or more 
    # paths. We match these paths to the path on incoming calls. 
    # To emulate this behavior for this routine, when running in report mode, we generate the 
    # same array of final behavior processing used in the CloudFront function that ultimately 
    # uses these behaviors.

    $Behaviors = $KvsEntry.behaviors  # default treatment
    $BehaviorsJson = $Behaviors | ConvertTo-Json -Depth 10
    Write-LzAwsVerbose $BehaviorsJson

    foreach($Behavior in $Behaviors) {
        $AssetType = $Behavior[1]

        if($S3Only -eq $true -and $AssetType -eq "api") {
            continue
        }

        $AssetName = Get-AssetName $KvsEntry $Behavior
        if($Report -eq $true) {
            $AssetNames += '' + $Behavior[1] + ' ' + $Behavior[0] + ' ' + $AssetName 
        } else {
            $AssetNames += $AssetName   
        }
    }
    return $AssetNames
}