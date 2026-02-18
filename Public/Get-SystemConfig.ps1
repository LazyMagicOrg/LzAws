function Get-SystemConfig {
	Write-LzAwsVerbose "Loading system configuration"

	# Try systemconfig.yaml first
	$FilePath = Find-FileUp "systemconfig.yaml" -ErrorAction SilentlyContinue
	$ConfigFileName = "systemconfig.yaml"

	# If systemconfig.yaml not found, resolve environment and try systemconfig.{env}.yaml
	if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
		Write-LzAwsVerbose "systemconfig.yaml not found, resolving environment"
		$EnvName = Get-Environment
		if ($null -ne $EnvName) {
			$ConfigFileName = "systemconfig.$EnvName.yaml"
			Write-LzAwsVerbose "Environment resolved to '$EnvName', looking for $ConfigFileName"
			$FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
		}
	}

	if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
		$errorMessage = @"
Error: Can't find system configuration file.
Function: Get-SystemConfig
Hints:
  - Are you running this from the root of a solution?
  - Do you have a systemconfig.yaml or systemconfig.{env}.yaml file in a folder above the solution folder?
  - Environment can be set via env.yaml (env: dev) or by having a _Dev*, _Test*, or _Prod* folder in the path
  - Check if the file name is exactly correct (case sensitive)
"@
		throw $errorMessage
	}

	Write-LzAwsVerbose "Using configuration file: $FilePath"

	try {
		$Config = Get-Content -Path $FilePath | ConvertFrom-Yaml
	} catch {
		$errorMessage = @"
Error: Failed to convert $ConfigFileName to a dictionary
Function: Get-SystemConfig
Hints:
  - Check if the $ConfigFileName file is valid YAML
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

	# Get region from config - Get-AWSCredential doesn't return region
	$Region = $Config.Region
	if ([string]::IsNullOrWhiteSpace($Region)) {
		$errorMessage = @"
Error: Region not specified in $ConfigFileName
Function: Get-SystemConfig
Hints:
  - Add a 'Region' property to your $ConfigFileName file
  - Example: Region: us-east-1
"@
		throw $errorMessage
	}

	$Value = @{
		Config = $Config
		Account = $CurrentProfile.AccountId
		Region = $Region
		ProfileName = $ProfileName
	}

	# Create module level variables for use in other module functions called after this function
	$script:Config = $Config
	$script:Account = $CurrentProfile.AccountId
	$script:Region = $Region
	$script:ProfileName = $ProfileName
	
	return $Value
}