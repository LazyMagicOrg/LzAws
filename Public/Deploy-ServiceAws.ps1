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
    Write-LzAwsVerbose "Starting service infrastructure deployment"  
    try {
        $SystemConfig = Get-SystemConfig 
        # Get-SystemConfig already handles exit 1 on failure

        $Config = $SystemConfig.Config
        if ($null -eq $Config) {
            Write-Host "Error: System configuration is missing Config section"
            Write-Host "Hints:"
            Write-Host "  - Check if Config section exists in systemconfig.yaml"
            Write-Host "  - Verify the configuration file structure"
            Write-Host "  - Ensure all required configuration sections are present"
            exit 1
        }

        $Environment = $Config.Environment
        $ProfileName = $Config.Profile
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $Config.SystemKey + "---service"
        $ArtifactsBucket = $Config.SystemKey + "---artifacts-" + $Config.SystemSuffix

        # Clean up existing artifacts
        try {
            Write-LzAwsVerbose "Removing existing S3 artifacts"
            aws s3 rm s3://$ArtifactsBucket/system/ --recursive --profile $ProfileName
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to remove existing S3 artifacts"
            }
        }
        catch {
            Write-Host "Error: Failed to clean up existing S3 artifacts"
            Write-Host "Hints:"
            Write-Host "  - Check if you have permission to delete S3 objects"
            Write-Host "  - Verify the S3 bucket exists and is accessible"
            Write-Host "  - Ensure AWS credentials are valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Build Lambda functions
        try {
            Write-LzAwsVerbose "Building Lambda functions"
            cd ..
            dotnet build -c Release
            if ($LASTEXITCODE -ne 0) {
                throw "Lambda build failed"
            }
            cd AWSTemplates
        }
        catch {
            Write-Host "Error: Failed to build Lambda functions"
            Write-Host "Hints:"
            Write-Host "  - Check if .NET SDK is installed and up to date"
            Write-Host "  - Verify all required NuGet packages are available"
            Write-Host "  - Review build errors in the output"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Package SAM template
        try {
            if(Test-Path "sam.Service.packages.yaml") {
                Remove-Item "sam.Service.packages.yaml"
            }

            Write-LzAwsVerbose "Packaging SAM template"
            sam package --template-file Generated/sam.Service.g.yaml `
                --output-template-file sam.Service.packaged.yaml `
                --s3-bucket $ArtifactsBucket `
                --s3-prefix system `
                --profile $ProfileName

            if ($LASTEXITCODE -ne 0) {
                throw "SAM packaging failed"
            }
        }
        catch {
            Write-Host "Error: Failed to package SAM template"
            Write-Host "Hints:"
            Write-Host "  - Check if the source template exists: Generated/sam.Service.g.yaml"
            Write-Host "  - Verify S3 bucket permissions"
            Write-Host "  - Ensure AWS credentials are valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Upload templates to S3
        try {
            Write-LzAwsVerbose "Uploading templates to S3"
            Set-Location Generated
            $Files = Get-ChildItem -Path . -Filter sam.*.yaml
            foreach ($File in $Files) {
                $FileName = $File.Name
                aws s3 cp $File.FullName s3://$ArtifactsBucket/system/$FileName --profile $ProfileName
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to upload template: $FileName"
                }
            }
            Set-Location ..
        }
        catch {
            Write-Host "Error: Failed to upload templates to S3"
            Write-Host "Hints:"
            Write-Host "  - Check if the Generated directory contains template files"
            Write-Host "  - Verify S3 bucket permissions"
            Write-Host "  - Ensure AWS credentials are valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Build parameters for stack deployment
        try {
            $ParametersDict = @{
                "SystemKeyParameter" = $SystemKey
                "EnvironmentParameter" = $Environment
                "ArtifactsBucketParameter" = $ArtifactsBucket
                "SystemSuffixParameter" = $SystemSuffix					
            }

            if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
                Write-Host "Error: deploymentconfig.g.yaml does not exist"
                Write-Host "Hints:"
                Write-Host "  - Run the generation step before deployment"
                Write-Host "  - Check if the generation process completed successfully"
                Write-Host "  - Verify the deployment configuration was generated"
                exit 1
            }

            $DeploymentConfig = Get-Content -Path "./Generated/deploymentconfig.g.yaml" | ConvertFrom-Yaml
            if ($null -eq $DeploymentConfig.Authentications) {
                Write-Host "Error: No authentication configurations found in deployment config"
                Write-Host "Hints:"
                Write-Host "  - Check if authentications are defined in the source config"
                Write-Host "  - Verify the generation process included authentications"
                Write-Host "  - Ensure the deployment config format is correct"
                exit 1
            }

            $Authentications = $DeploymentConfig.Authentications
            foreach($Authentication in $Authentications) {
                $Name = $Authentication.Name
                $AuthStackName = $Config.SystemKey + "---" + $Name
                Write-LzAwsVerbose "Processing auth stack: $AuthStackName"

                try {
                    # Get auth stack outputs
                    Write-LzAwsVerbose "Getting stack outputs for '$AuthStackName'"
                    try {
                        $AuthStackOutputDict = Get-StackOutputs $AuthStackName
                        Write-LzAwsVerbose "Retrieved $($AuthStackOutputDict.Count) stack outputs"
                        if ($null -eq $AuthStackOutputDict["UserPoolId"] -or $null -eq $AuthStackOutputDict["UserPoolClientId"] -or $null -eq $AuthStackOutputDict["SecurityLevel"]) {
                            Write-Host "Error: Missing required outputs from auth stack '$AuthStackName'"
                            Write-Host "Hints:"
                            Write-Host "  - Check if the auth stack was deployed successfully"
                            Write-Host "  - Verify the auth stack template includes all required outputs"
                            Write-Host "  - Ensure the auth resources were created properly"
                            exit 1
                        }
                    }
                    catch {
                        Write-Host "Error: Failed to get auth stack outputs"
                        Write-Host "Hints:"
                        Write-Host "  - Verify the auth stack exists"
                        Write-Host "  - Check if you have permission to read stack outputs"
                        Write-Host "  - Ensure the stack name is correct: $AuthStackName"
                        Write-Host "Error Details: $($_.Exception.Message)"
                        exit 1
                    }

                    $ParametersDict.Add($Name + "UserPoolIdParameter", $AuthStackOutputDict["UserPoolId"])
                    $ParametersDict.Add($Name + "UserPoolClientIdParameter", $AuthStackOutputDict["UserPoolClientId"])
                    $ParametersDict.Add($Name + "IdentityPoolIdParameter", $AuthStackOutputDict["IdentityPoolId"])
                    $ParametersDict.Add($Name + "SecurityLevelParameter", $AuthStackOutputDict["SecurityLevel"])
                    $ParametersDict.Add($Name + "UserPoolArnParameter", $AuthStackOutputDict["UserPoolArn"])
                }
                catch {
                    Write-Host "Error: Failed to process auth stack '$AuthStackName'"
                    Write-Host "Hints:"
                    Write-Host "  - Verify the auth stack exists and is deployed"
                    Write-Host "  - Check if you have permission to read stack outputs"
                    Write-Host "  - Ensure all required outputs are defined in the template"
                    Write-Host "Error Details: $($_.Exception.Message)"
                    exit 1
                }
            }
        }
        catch {
            Write-Host "Error: Failed to prepare stack parameters"
            Write-Host "Hints:"
            Write-Host "  - Check if deploymentconfig.g.yaml is valid YAML"
            Write-Host "  - Verify the configuration format is correct"
            Write-Host "  - Ensure all required parameters are present"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Deploy the service stack
        try {
            Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
            $Parameters = ConvertTo-ParameterOverrides -parametersDict $ParametersDict

            sam deploy `
                --template-file sam.Service.packaged.yaml `
                --s3-bucket $ArtifactsBucket `
                --stack-name $StackName `
                --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM `
                --parameter-overrides $Parameters `
                --profile $ProfileName

            if ($LASTEXITCODE -ne 0) {
                throw "SAM deployment failed with exit code $LASTEXITCODE"
            }

            Write-Host "Successfully deployed service stack" -ForegroundColor Green
        }
        catch {
            Write-Host "Error: Failed to deploy service stack"
            Write-Host "Hints:"
            Write-Host "  - Check AWS CloudFormation console for detailed errors"
            Write-Host "  - Verify you have required IAM permissions"
            Write-Host "  - Ensure the template syntax is correct"
            Write-Host "  - Validate the parameter values"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
    }
    catch {
        Write-Host "Error: An unexpected error occurred during service deployment"
        Write-Host "Hints:"
        Write-Host "  - Check the AWS CloudFormation console for stack status"
        Write-Host "  - Verify all required AWS services are available"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}

