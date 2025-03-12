# Transform a config Behaviors property into a hash table of behavior entries where
# the key is the path and the values have a form suitable for the type.
# We do this to reduce the character count in the KVS value. We are limited to 
# 1024 characters in the KVS value.
#
# Example:
# $myRegion = us-west-2
# $myEnvironment = dev
# Behaviors:
#   Apis:
#   - Path: "/PublicApi"
#     ApiName: "PublicApi"
#   Assets:
#   - Path: "/system/"
#   WebApps:
#   - Path: "/store/,/store,/"
#     AppName: "storeapp"
#
# becomes 
#                                  [path,assetType,apiname,region,env]
#  behaviors["/PublicApi"]      = @[ "/PublicApi", "api", "kdkdkd", "us-west-2", "dev" ]
#
#                                  [path,assetType,guid,region,level]
#  behaviors["/system"]         = @[ "/system", "assets", "{ss}", "us-west-2" ]]
#
#                                  [path,assetType,appName,guid,region,level]
#  behaviors["/store,/store,/"] = @[ "/store", "assets", "1234", "us-west-2" ]

function Get-BehaviorsHashTable($MySuffixRepl,$MyEnvironment,$MyRegion,$MyBehaviors, $MyServiceStackOutputDict, $MyLevel)
{
    # $MySuffixRepl is one of {ss}, {ts}, {sts}
    # $MyBehaviors is the Behaviors property from the config file. 

    $Behaviors = @()

    # Assets entry
    $MyAssets = Get-HashTableFromBehaviorArray($MyBehaviors.Assets)
    foreach($Asset in $MyAssets.Values) {
        # [path,assetType,suffix,region,level]
        $Suffix = if ($null -eq $Asset.Suffix) { $MySuffixRepl } else { $Asset.Suffix }
        $Region = if ($null -eq $Asset.Region) { $MyRegion } else { $Asset.Region }

        $Behaviors += ,@(
            $Asset.Path,
            "assets",
            $Suffix,
            $Region,
            $MyLevel
        )
    }

    # WebApp entry
    $MyWebApps = Get-HashTableFromBehaviorArray($MyBehaviors.WebApps)
    foreach($WebApp in $MyWebApps.Values) {
        # [path,assetType,appName,suffix,region,level]
        $Suffix = if ($null -eq $WebApp.Suffix) { $MySuffixRepl } else { $WebApp.Suffix }
        $Region = if ($null -eq $WebApp.Region) { $MyRegion } else { $WebApp.Region }
        $Behaviors += ,@(
            $WebApp.Path,
            "webapp",
            $WebApp.AppName,
            $Suffix,
            $Region,
            $MyLevel
        )
    }

    # API entry
    $MyApis = Get-HashTableFromBehaviorArray($MyBehaviors.Apis)
    foreach($Api in $MyApis.Values) {
        # [path,assetType,apiname,region,env]
        $Region = if ($null -eq $Api.Region) { $MyRegion } else { $Api.Region }
        $Behaviors += ,@(
            $Api.Path,
            "api",
            $MyServiceStackOutputDict[($Api.ApiName + "Id")],
            $Region,
            $MyEnvironment
        )
    }

    # Map behaviors with path as key
    $BehaviorHash = @{}
    foreach($Behavior in $Behaviors) {
        $BehaviorHash[$Behavior[0]] = $Behavior
    }
    return $BehaviorHash
}
