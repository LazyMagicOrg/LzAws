function Get-TenantKVSEntry($SystemKey,$SystemSuffix,$Environment,$Region,$SystemBehaviorsHash,$TenantKey,$Tenant, $ServiceStackOutputDict) {
    $TenantConfig = @{
        env = $Environment
        region = $Region 
        systemKey = $SystemKey
        tenantKey = $TenantKey
        ss = $SystemSuffix
        ts = $Tenant.TenantSuffix ?? "{ss}"
        behaviors = @()
    }

    $BehaviorsHash = @{} + $SystemBehaviorsHash # clone
    $TenantBehaviorsHash = (Get-BehaviorsHashTable "{ts}" $Environment $Region $Tenant.Behaviors $ServiceStackOutputDict 1)
    # append method compatible with all powershell versions
    $TenantBehaviorsHash.Keys | ForEach-Object {
        $BehaviorsHash[$_] = $TenantBehaviorsHash[$_]
    }
    $TenantConfig.behaviors = $BehaviorsHash.Values

    # $TenantConfigJson = $TenantConfig | ConvertTo-Json
    # Write-Host $TenantConfigJson

    return $TenantConfig
}