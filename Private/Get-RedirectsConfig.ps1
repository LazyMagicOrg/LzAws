# This script generates redirects config json from the 
# redirects information in the systemconfig.yaml file. 
#
# Each redirects object contains the 
# KVS entry we publish to the CloudFront KVS.
# The structure of the tenant config object is:
#   {
#       "domain" :  
#       {
#           "redirecthost": string,
#           "redirecturi": string
#       }
#   }
#

function Get-RedirectsConfig {
    
    Write-LzAwsVerbose "Getting redirect entries"  

    $SystemConfig = Get-SystemConfig 
    
    # Check if redirects property exists
    if (-not ($SystemConfig.PSObject.Properties.Match('redirects'))) {
        Write-LzAwsVerbose "No redirects configuration found in system config"
        return "{}"
    }
    
    $RedirectsConfig = $SystemConfig.redirects

    $RedirectConfigJson = $RedirectsConfig | ConvertTo-Json -Depth 10  
    return $RedirectConfigJson
}