function Get-SubtenantKVSEntry($ProcessedTenant, $Subtenant, $SubTenantKey, $ServiceStackOutputDict) {
    $TenantConfig = @{
        env = $ProcessedTenant.env
        region = $ProcessedTenant.region
        systemKey = $ProcessedTenant.systemKey
        tenantKey = $ProcessedTenant.tenantKey
        subtenantKey = $SubTenantKey
        ss = $ProcessedTenant.ss
        ts = $ProcessedTenant.ts
        sts = $Subtenant.SubTenantSuffix ?? "{ts}"
        behaviors = @()
    }
   
    $BehaviorsHash = Get-HashTableFromProcessedBehaviorArray $ProcessedTenant.behaviors
    $SubtenantBehaviorsHash = (Get-BehaviorsHashTable "{sts}" $ProcessedTenant.env $ProcessedTenant.region $Subtenant.Behaviors $ServiceStackOutputDict 2)
    $SubtenantBehaviorsHash.Keys | ForEach-Object {
        $BehaviorsHash[$_] = $SubtenantBehaviorsHash[$_]
    }

    $TenantConfig.behaviors = $BehaviorsHash.Values
    # $TenantConfigJson = $TenantConfig | ConvertTo-Json
    # Write-Host $TenantConfigJson

    return $TenantConfig
}