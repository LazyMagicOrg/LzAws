function Get-SystemConfig {
	Write-LzAwsVerbose "Loading systemconfig.yaml"
	# Load the systemconfig.yaml file
	$FilePath = Find-FileUp "systemconfig.yaml" -ErrorAction SilentlyContinue

	if($null -eq $FilePath -or -not (Test-Path $FilePath)) {
		$errorMessage = @"
Error: Can't find systemconfig.yaml.
Function: Get-SystemConfig
Hints:
  - Are you running this from the root of a solution?
  - Do you have a systemconfig.yaml file in a folder above the solution folder?
  - Check if the file name is exactly 'systemconfig.yaml' (case sensitive)
"@
		throw $errorMessage
	}

	try {
		$Config = Get-Content -Path $FilePath | ConvertFrom-Yaml
	} catch {
		$errorMessage = @"
Error: Failed to convert systemconfig.yaml to a dictionary
Function: Get-SystemConfig
Hints:
  - Check if the systemconfig.yaml file is valid YAML
  - Ensure the file is not corrupted or missing any required fields
  - Verify the file is in the correct format
"@
		throw $errorMessage
	}
	
	$ProfileName = $Config.Profile

	try {
		Set-AWSCredential -ProfileName $ProfileName  -Scope Global
	} catch {
		$errorMessage = @"
Error: Failed to set AWS profile to '$ProfileName'
Function: Get-SystemConfig
Hints:
  - Have you logged in? aws sso login --profile $ProfileName
  - Check if the profile exists in your AWS credentials file
  - Verify the profile has valid credentials
  - Try running 'aws configure list-profiles' to see available profiles
"@
		throw $errorMessage
	}

	# Load System level configuration properties we process
	$CurrentProfile = Get-AWSCredential
	$Value = @{
		Config = $Config
		Account = $CurrentProfile.accountId
		Region = $CurrentProfile.region
		ProfileName = $ProfileName
	}
	
	# Create module level variables for use in other module functions called after this function
	$script:Config = $Config
	$script:Account = $CurrentProfile.accountId
	$script:Region = $CurrentProfile.region
	$script:ProfileName = $ProfileName
	
	return $Value
}