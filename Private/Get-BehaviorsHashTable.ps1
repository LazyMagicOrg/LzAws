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

function Get-BehaviorsHashTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$MySuffixRepl,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$MyEnvironment,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$MyRegion,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$MyBehaviors,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$MyServiceStackOutputDict,
        
        [Parameter(Mandatory=$true)]
        [ValidateRange(0, 2)]
        [int]$MyLevel
    )

    Write-LzAwsVerbose "Processing behaviors with suffix replacement '$MySuffixRepl' at level $MyLevel"

    if ($null -eq $MyBehaviors) {
        $errorMessage = @"
Error: Behaviors configuration is required
Function: Get-BehaviorsHashTable
Hints:
  - Check if behaviors are defined in systemconfig.yaml
  - Verify the behaviors object is not null
  - Ensure behaviors are properly configured
  - Review the system configuration file structure
"@
        throw $errorMessage
    }

    if ($null -eq $MyServiceStackOutputDict) {
        $errorMessage = @"
Error: Service stack outputs are required
Function: Get-BehaviorsHashTable
Hints:
  - Check if service stack exists
  - Verify stack outputs are available
  - Ensure stack deployment completed successfully
  - Review the CloudFormation stack outputs
"@
        throw $errorMessage
    }

    $Behaviors = @()

    try {
        # Assets entry
        $MyAssets = Get-HashTableFromBehaviorArray($MyBehaviors.Assets)
        if ($null -eq $MyAssets) {
            $errorMessage = @"
Error: Failed to process asset behaviors
Function: Get-BehaviorsHashTable
Hints:
  - Check asset behavior configuration
  - Verify asset paths are properly formatted
  - Ensure asset properties are valid
  - Review the asset behavior structure
"@
            throw $errorMessage
        }
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
        if ($null -eq $MyWebApps) {
            $errorMessage = @"
Error: Failed to process webapp behaviors
Function: Get-BehaviorsHashTable
Hints:
  - Check webapp behavior configuration
  - Verify webapp paths are properly formatted
  - Ensure webapp properties are valid
  - Review the webapp behavior structure
"@
            throw $errorMessage
        }
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
        if ($null -eq $MyApis) {
            $errorMessage = @"
Error: Failed to process API behaviors
Function: Get-BehaviorsHashTable
Hints:
  - Check API behavior configuration
  - Verify API paths are properly formatted
  - Ensure API properties are valid
  - Review the API behavior structure
"@
            throw $errorMessage
        }
        foreach($Api in $MyApis.Values) {
            # [path,assetType,apiname,region,env]
            $Region = if ($null -eq $Api.Region) { $MyRegion } else { $Api.Region }
            $ApiId = $MyServiceStackOutputDict[($Api.ApiName + "Id")]
            if ($null -eq $ApiId) {
                $errorMessage = @"
Error: API ID not found for API '$($Api.ApiName)'
Function: Get-BehaviorsHashTable
Hints:
  - Check if the API is deployed
  - Verify the API name matches the stack output
  - Ensure the service stack has the API ID output
  - Review the CloudFormation stack outputs
"@
                throw $errorMessage
            }
            $Behaviors += ,@(
                $Api.Path,
                "api",
                $ApiId,
                $Region,
                $MyEnvironment
            )
        }
    }
    catch {
        $errorMessage = @"
Error: Failed to process behavior arrays
Function: Get-BehaviorsHashTable
Hints:
  - Check behavior array format
  - Verify all required properties are present
  - Ensure behavior values are valid
  - Review the behavior array structure

Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
    }

    # Map behaviors with path as key
    $BehaviorHash = @{}
    foreach($Behavior in $Behaviors) {
        $BehaviorHash[$Behavior[0]] = $Behavior
    }

    Write-LzAwsVerbose "Successfully processed $($Behaviors.Count) behaviors"
    return $BehaviorHash
}
