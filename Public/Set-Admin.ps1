<#
.SYNOPSIS
    Creates an admin user in a user pool
.DESCRIPTION
    Creates an admin user in the user pool if it doesn't exist

.PARAMETER None
    This cmdlet does not accept parameters directly, but reads from system configuration
.EXAMPLE
    Set-Admin
    Creates an admin user in the user pool
.NOTES
    - Must be run from the Tenancy Solution root folder
.OUTPUTS
    None
#>

function Set-Admin {
    [CmdletBinding()]
    param()	
    try {

        Write-LzAwsVerbose "Deploying Authentication stack(s)"  
        $null = Get-SystemConfig 
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $SystemKey = $Config.SystemKey
        $AdminAuth = $Config.AdminAuth
        $AdminEmail = $Config.AdminEmail

        # Get user pool id
        $AuthStackName = $SystemKey + "---" + $AdminAuth
        Write-Host "AuthStackName: $AuthStackName"
        $StackOutputs = Get-StackOutputs $AuthStackName
        $UserPoolId = $StackOutputs["UserPoolId"]

        $getCommand = "aws cognito-idp get-user --user-pool-id $UserPoolId --username Administrator --profile $ProfileName"
        $result = Invoke-Expression $getCommand 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-LzAwsVerbose "Admin user does not exist. Creating..."
            $result = aws cognito-idp admin-create-user `
                --user-pool-id $UserPoolId `
                --username Administrator `
                --temporary-password 'Initial123!' `
                --user-attributes "Name=email,Value=`"$AdminEmail`"" `
                --profile $ProfileName `
                --region $Region 2>&1
            
            $exitCode = $LASTEXITCODE
           
            if ($exitCode -ne 0) {
                $errorMessage = @"
Error: Failed to create admin user
Function: Set-Admin
Hints:
  - Check if you have sufficient AWS permissions
  - Verify the user pool ID is correct
  - Ensure the admin email is valid
  - email: $AdminEmail
Error Details: $($result | Out-String)
"@
                throw $errorMessage
            }
            Write-LzAwsVerbose "Admin user created successfully"
        } else {
            Write-LzAwsVerbose "Admin user already exists"
        }
    } catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}