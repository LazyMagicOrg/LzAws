<#
.SYNOPSIS
    Deploys service infrastructure and resources to AWS
.DESCRIPTION
    Deploys or updates service infrastructure in AWS using CloudFormation/SAM templates.
    This includes deploying Lambda functions, configuring authentication resources,
    and setting up other required AWS services.
.PARAMETER None
    This cmdlet does not accept any parameters. It uses system configuration files
    to determine deployment settings.
.EXAMPLE
    Deploy-ServiceAws
    Deploys the service infrastructure using settings from configuration files
.NOTES
    - Requires valid AWS credentials and appropriate permissions
    - Must be run from the AWSTemplates directory
    - Requires system configuration files and SAM templates
    - Will package and upload Lambda functions
    - Will configure the use of authentication resources created with Deploy-AuthsAws
.OUTPUTS
    None
#>
function Deploy-ServiceAws {
    [CmdletBinding()]
    param()	
	Write-LzAwsVerbose "Deploying system artifacts stack"  
	try {
		$SystemConfig = Get-SystemConfig 
		$Config = $SystemConfig.Config
		$Environment = $Config.Environment
		$ProfileName = $Config.Profile
		$SystemKey = $Config.SystemKey
		$SystemSuffix = $Config.SystemSuffix

		$StackName = $Config.SystemKey + "---service"

		$ArtifactsBucket = $Config.SystemKey + "---artifacts-" + $Config.SystemSuffix

		# Removing existing s3 artifacts files. DON'T do this in a test or prod environment! Deployed Lambda starts would fail.
		aws s3 rm s3://$ArtifactsBucket/system/ --recursive --profile $ProfileName
		cd ..
		Write-LzAwsVerbose "Building Lambdas"
		dotnet build -c Release

		cd AWSTemplates

		if(Test-Path "sam.Service.packages.yaml") {
				Remove-Item "sam.Service.packages.yaml"
		}

		# Note that sam requires we explicitly set the --profile
		sam package --template-file Generated/sam.Service.g.yaml `
		--output-template-file sam.Service.packaged.yaml `
		--s3-bucket $ArtifactsBucket `
		--s3-prefix system `
		--profile $ProfileName

		Write-LzAwsVerbose "Uploading templates to s3"
		Set-Location Generated
		$Files = Get-ChildItem -Path . -Filter sam.*.yaml
		foreach ($File in $Files) {
			$FileName = $File.Name
			aws s3 cp $File.FullName s3://$ArtifactsBucket/system/$FileName --profile $ProfileName
		}
		# back to the AwsTemplates directory
		Set-Location ..

		# Build parameters for stack deployment
		$ParametersDict = @{
			"SystemKeyParameter" = $SystemKey
			"EnvironmentParameter" = $Environment
			"ArtifactsBucketParameter" = $ArtifactsBucket
			"SystemSuffixParameter" = $SystemSuffix					
		}

		if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
			throw "deploymentconfig.yaml does not exist."
		}

		$DeploymentConfig = Get-Content -Path "./Generated/deploymentconfig.g.yaml" | ConvertFrom-Yaml
		$Authentications = $DeploymentConfig.Authentications

		# Generate the authenticator parameters
		foreach($Authentication in $Authentications) {
			$Name = $Authentication.Name
			$AuthStackName = $Config.SystemKey + "---" + $Name
			$AuthStackOutputs = Get-StackOutputs $AuthStackName
			Write-Host "Processing auth stack: $AuthStackName"
			$ParametersDict.Add($Name + "UserPoolIdParameter", $AuthStackOutputs["UserPoolId"])
			$ParametersDict.Add($Name + "UserPoolClientIdParameter", $AuthStackOutputs["UserPoolClientId"])
			$ParametersDict.Add($Name + "IdentityPoolIdParameter", $AuthStackOutputs["IdentityPoolId"])
			$ParametersDict.Add($Name + "SecurityLevelParameter", $AuthStackOutputs["SecurityLevel"])
			$ParametersDict.Add($Name + "UserPoolArnParameter", $AuthStackOutputs["UserPoolArn"])
		}  

		Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 

		$Parameters = ConvertTo-ParameterOverrides -parametersDict $ParametersDict

		# Note that sam requires we explicitly set the --profile	
		sam deploy `
		--template-file sam.Service.packaged.yaml `
		--s3-bucket $ArtifactsBucket `
		--stack-name $StackName `
		--capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM `
		--parameter-overrides $Parameters `
		--profile $ProfileName
	}
	catch {
		throw
	}
}

