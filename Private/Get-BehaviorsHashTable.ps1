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

    try {
        Write-LzAwsVerbose "Processing behaviors with suffix replacement '$MySuffixRepl' at level $MyLevel"

        if ($null -eq $MyBehaviors) {
            Write-Host "Error: Behaviors configuration is required"
            Write-Host "Hints:"
            Write-Host "  - Check if behaviors are defined in systemconfig.yaml"
            Write-Host "  - Verify the behaviors object is not null"
            Write-Host "  - Ensure behaviors are properly configured"
            Write-Error "Behaviors configuration is required" -ErrorAction Stop
        }

        if ($null -eq $MyServiceStackOutputDict) {
            Write-Host "Error: Service stack outputs are required"
            Write-Host "Hints:"
            Write-Host "  - Check if service stack exists"
            Write-Host "  - Verify stack outputs are available"
            Write-Host "  - Ensure stack deployment completed successfully"
            Write-Error "Service stack outputs are required" -ErrorAction Stop
        }

        $Behaviors = @()

        try {
            # Assets entry
            $MyAssets = Get-HashTableFromBehaviorArray($MyBehaviors.Assets)
            if ($null -eq $MyAssets) {
                Write-Host "Error: Failed to process asset behaviors"
                Write-Host "Hints:"
                Write-Host "  - Check asset behavior configuration"
                Write-Host "  - Verify asset paths are properly formatted"
                Write-Host "  - Ensure asset properties are valid"
                Write-Error "Failed to process asset behaviors" -ErrorAction Stop
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
                Write-Host "Error: Failed to process webapp behaviors"
                Write-Host "Hints:"
                Write-Host "  - Check webapp behavior configuration"
                Write-Host "  - Verify webapp paths are properly formatted"
                Write-Host "  - Ensure webapp properties are valid"
                Write-Error "Failed to process webapp behaviors" -ErrorAction Stop
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
                Write-Host "Error: Failed to process API behaviors"
                Write-Host "Hints:"
                Write-Host "  - Check API behavior configuration"
                Write-Host "  - Verify API paths are properly formatted"
                Write-Host "  - Ensure API properties are valid"
                Write-Error "Failed to process API behaviors" -ErrorAction Stop
            }
            foreach($Api in $MyApis.Values) {
                # [path,assetType,apiname,region,env]
                $Region = if ($null -eq $Api.Region) { $MyRegion } else { $Api.Region }
                $ApiId = $MyServiceStackOutputDict[($Api.ApiName + "Id")]
                if ($null -eq $ApiId) {
                    Write-Host "Error: API ID not found for API '$($Api.ApiName)'"
                    Write-Host "Hints:"
                    Write-Host "  - Check if the API is deployed"
                    Write-Host "  - Verify the API name matches the stack output"
                    Write-Host "  - Ensure the service stack has the API ID output"
                    Write-Host "API: $($Api.ApiName)"
                    Write-Error "API ID not found for API '$($Api.ApiName)'" -ErrorAction Stop
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
            Write-Host "Error: Failed to process behavior arrays"
            Write-Host "Hints:"
            Write-Host "  - Check behavior array format"
            Write-Host "  - Verify all required properties are present"
            Write-Host "  - Ensure behavior values are valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to process behavior arrays: $($_.Exception.Message)" -ErrorAction Stop
        }

        # Map behaviors with path as key
        $BehaviorHash = @{}
        foreach($Behavior in $Behaviors) {
            $BehaviorHash[$Behavior[0]] = $Behavior
        }

        Write-LzAwsVerbose "Successfully processed $($Behaviors.Count) behaviors"
        return $BehaviorHash
    }
    catch {
        Write-Host "Error: Failed to generate behaviors hash table"
        Write-Host "Hints:"
        Write-Host "  - Check behavior configuration in systemconfig.yaml"
        Write-Host "  - Verify all required properties are present"
        Write-Host "  - Ensure behavior values are valid"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "Failed to generate behaviors hash table: $($_.Exception.Message)" -ErrorAction Stop
    }
}
