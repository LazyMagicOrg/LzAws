<#
.SYNOPSIS
    Builds and deploys a Docker container to AWS ECR
.DESCRIPTION
    Builds a Docker container image and pushes it to AWS Elastic Container Registry (ECR).
    This cmdlet prepares the NuGet package cache, builds the Docker image, and pushes it to ECR.
    The ECR repository must already exist (created by Deploy-SystemAws).
.PARAMETER ContainerName
    The name of the container to build and deploy (e.g., "ChatAppRunner")
.PARAMETER ImageTag
    The tag to apply to the Docker image. Defaults to "latest"
.EXAMPLE
    Deploy-DockerAws -ContainerName "ChatAppRunner"
    Builds and deploys the ChatAppRunner container with the "latest" tag
.EXAMPLE
    Deploy-DockerAws -ContainerName "ChatAppRunner" -ImageTag "v1.0.0"
    Builds and deploys the ChatAppRunner container with a custom version tag
.NOTES
    - Requires Docker Desktop to be running
    - Requires valid AWS credentials and appropriate permissions
    - Must be run from the Service/AWSTemplates directory (like other Deploy-* commands)
    - The ECR repository must exist (created by Deploy-SystemAws)
    - Uses systemconfig.yaml for AWS configuration
    - Automatically prepares Docker package cache from NuGet cache
.OUTPUTS
    Boolean - Returns $true on success, $false on failure
#>
function Deploy-DockerAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ContainerName,

        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$ImageTag = "latest"
    )

    Write-LzAwsVerbose "Starting Docker container deployment for '$ContainerName'"

    try {
        # Step 1: Validate Docker is installed and running
        Write-LzAwsVerbose "Checking if Docker is installed and running"
        try {
            $dockerVersion = docker version --format '{{.Server.Version}}' 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errorMessage = @"
Error: Docker daemon is not running
Function: Deploy-DockerAws
Hints:
  - Start Docker Desktop
  - Wait for Docker Desktop to fully initialize
  - Verify Docker is running with: docker ps
"@
                throw $errorMessage
            }
            Write-LzAwsVerbose "Docker is running (version: $dockerVersion)"
        }
        catch {
            $errorMessage = @"
Error: Failed to communicate with Docker daemon
Function: Deploy-DockerAws
Hints:
  - Ensure Docker Desktop is installed
  - Start Docker Desktop and wait for it to fully initialize
  - Verify Docker is accessible with: docker ps
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Step 2: Validate we're in the AWSTemplates directory with correct structure
        Write-LzAwsVerbose "Validating AWSTemplates directory structure"

        # Check if we're in AWSTemplates folder
        $currentDir = Get-Location
        if ((Split-Path $currentDir -Leaf) -ne "AWSTemplates") {
            $errorMessage = @"
Error: Must be run from the AWSTemplates directory
Function: Deploy-DockerAws
Hints:
  - Navigate to the AWSTemplates directory
  - Current directory: $currentDir
  - Run: cd Service/AWSTemplates
"@
            throw $errorMessage
        }

        # Dockerfile is relative to Service directory (parent of AWSTemplates)
        $dockerfilePath = "../Containers/$ContainerName/Dockerfile"
        if (-not (Test-Path $dockerfilePath)) {
            $errorMessage = @"
Error: Dockerfile not found at expected location
Function: Deploy-DockerAws
Hints:
  - Expected location: Service/Containers/$ContainerName/Dockerfile
  - Current directory: $(Get-Location)
  - Verify the container name is correct
"@
            throw $errorMessage
        }

        # Step 3: Get system configuration
        Write-LzAwsVerbose "Loading system configuration"
        $SystemConfig = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Account = $script:Account
        $Config = $SystemConfig.Config

        if ($null -eq $Config) {
            $errorMessage = @"
Error: System configuration is missing
Function: Deploy-DockerAws
Hints:
  - Check if systemconfig.yaml exists
  - Verify the configuration file structure
  - Ensure all required configuration sections are present
"@
            throw $errorMessage
        }

        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix
        $Environment = $Config.Environment

        # Construct the stack name to match CloudFormation naming
        $StackName = "$SystemKey-$SystemSuffix-$Environment"

        # Step 4: Construct ECR repository details
        # Each container has its own ECR repository scoped by stack name
        $EcrRepositoryName = "$StackName-$($ContainerName.ToLower())"
        $EcrRepositoryUri = "$Account.dkr.ecr.$Region.amazonaws.com"
        $ImageName = $ContainerName.ToLower()
        $FullImageUri = "${EcrRepositoryUri}/${EcrRepositoryName}:${ImageTag}"

        Write-Host "======================================"
        Write-Host "Docker Container Deployment"
        Write-Host "======================================"
        Write-Host "Container Name: $ContainerName"
        Write-Host "Image Tag: $ImageTag"
        Write-Host "ECR Repository: $EcrRepositoryName"
        Write-Host "Full Image URI: $FullImageUri"
        Write-Host "AWS Profile: $ProfileName"
        Write-Host "AWS Region: $Region"
        Write-Host "======================================"

        # Step 5: Ensure ECR repository exists
        Write-LzAwsVerbose "Checking if ECR repository exists"
        Write-Host "Checking ECR repository..."

        $awsCommand = if ($IsWindows -or $env:OS -match "Windows") { "aws" } else { "aws.exe" }

        $repoCheck = & $awsCommand ecr describe-repositories `
            --profile $ProfileName `
            --region $Region `
            --repository-names $EcrRepositoryName 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-LzAwsVerbose "ECR repository already exists"
        }
        else {
            # Repository doesn't exist, create it
            Write-Host "Creating ECR repository '$EcrRepositoryName'..."
            try {
                $createResult = & $awsCommand ecr create-repository `
                    --profile $ProfileName `
                    --region $Region `
                    --repository-name $EcrRepositoryName `
                    --image-scanning-configuration scanOnPush=true `
                    --tags "Key=Environment,Value=$Environment" "Key=Container,Value=$ContainerName" 2>&1

                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create ECR repository: $createResult"
                }
                Write-LzAwsVerbose "Successfully created ECR repository"

                # Set lifecycle policy to keep last 10 images
                $lifecyclePolicy = @'
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 10 images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
'@
                $policyResult = & $awsCommand ecr put-lifecycle-policy `
                    --profile $ProfileName `
                    --region $Region `
                    --repository-name $EcrRepositoryName `
                    --lifecycle-policy-text $lifecyclePolicy 2>&1

                if ($LASTEXITCODE -ne 0) {
                    Write-LzAwsVerbose "Warning: Could not set lifecycle policy (non-critical): $policyResult"
                }
            }
            catch {
                $errorMessage = @"
Error: Failed to create ECR repository
Function: Deploy-DockerAws
Hints:
  - Check if you have permission to create ECR repositories
  - Verify AWS credentials are valid: aws sts get-caller-identity --profile $ProfileName
  - Ensure you have ecr:CreateRepository permission
Error Details: $($_.Exception.Message)
"@
                throw $errorMessage
            }
        }

        # Step 6: Authenticate Docker to ECR
        Write-LzAwsVerbose "Authenticating Docker to ECR"
        Write-Host "Authenticating to ECR..."
        try {
            $loginPassword = & $awsCommand ecr get-login-password --profile $ProfileName --region $Region 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to get ECR login password: $loginPassword"
            }

            $loginResult = $loginPassword | docker login --username AWS --password-stdin $EcrRepositoryUri 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to authenticate Docker to ECR: $loginResult"
            }
            Write-LzAwsVerbose "Successfully authenticated to ECR"
        }
        catch {
            $errorMessage = @"
Error: Failed to authenticate Docker to ECR
Function: Deploy-DockerAws
Hints:
  - Check if you have permission to access ECR
  - Verify AWS credentials are valid: aws sts get-caller-identity --profile $ProfileName
  - Try: aws ecr describe-repositories --profile $ProfileName --region $Region
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Step 7: Synchronize Docker packages
        Write-LzAwsVerbose "Synchronizing Docker packages using Sync-DockerPackages function"
        Write-Host "Synchronizing NuGet packages for Docker build..."
        try {
            $serviceDir = Split-Path $PWD -Parent

            # Change to Service directory to run the function
            Push-Location $serviceDir
            try {
                # Project path relative to Service directory
                $projectPath = "Containers/$ContainerName/$ContainerName.csproj"

                # Call the module function directly
                $syncResult = Sync-DockerPackages -ProjectPath $projectPath

                if (-not $syncResult) {
                    throw "Sync-DockerPackages function returned false"
                }
                Write-LzAwsVerbose "Successfully synchronized Docker packages"
            }
            finally {
                Pop-Location
            }
        }
        catch {
            $errorMessage = @"
Error: Failed to synchronize Docker packages
Function: Deploy-DockerAws
Hints:
  - Ensure all required NuGet packages are available in the local cache
  - Verify Directory.Packages.props has correct package versions
  - Check that dotnet SDK is installed and accessible
  - Try running: Sync-DockerPackages -ProjectPath "Containers/$ContainerName/$ContainerName.csproj"
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Step 8: Build the Docker image
        Write-LzAwsVerbose "Building Docker image from Service directory"
        Write-Host "Building Docker image '$ImageName'..."
        try {
            # Docker build context must be Service directory (parent of AWSTemplates)
            # Run from parent directory with -f flag to specify Dockerfile location
            $buildResult = docker build -f $dockerfilePath --build-arg ContainerName=$ContainerName -t $ImageName .. 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build failed: $buildResult"
            }
            Write-LzAwsVerbose "Successfully built Docker image"
        }
        catch {
            $errorMessage = @"
Error: Failed to build Docker image
Function: Deploy-DockerAws
Hints:
  - Check the Dockerfile for syntax errors
  - Ensure all required files are present in the build context
  - Review the build output for specific errors
  - Verify there is enough disk space for the build
  - Try running: Sync-DockerPackages -ProjectPath "Containers/$ContainerName/$ContainerName.csproj"
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Step 9: Tag the image for ECR
        Write-LzAwsVerbose "Tagging image for ECR"
        Write-Host "Tagging image for ECR..."
        try {
            $tagResult = docker tag "${ImageName}:latest" $FullImageUri 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Docker tag failed: $tagResult"
            }
            Write-LzAwsVerbose "Successfully tagged image"
        }
        catch {
            $errorMessage = @"
Error: Failed to tag Docker image
Function: Deploy-DockerAws
Hints:
  - Ensure the image was built successfully
  - Verify the image name and tag are valid
  - Check Docker images with: docker images
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Step 10: Push the image to ECR
        Write-LzAwsVerbose "Pushing image to ECR"
        Write-Host "Pushing image to ECR (this may take a few minutes)..."
        try {
            $pushResult = docker push $FullImageUri 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Docker push failed: $pushResult"
            }
            Write-LzAwsVerbose "Successfully pushed image to ECR"
        }
        catch {
            $errorMessage = @"
Error: Failed to push Docker image to ECR
Function: Deploy-DockerAws
Hints:
  - Check if you have permission to push to ECR
  - Verify the ECR repository exists
  - Ensure you have sufficient ECR storage quota
  - Try: aws ecr describe-repositories --repository-name $EcrRepositoryName --profile $ProfileName --region $Region
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Step 11: Verify the upload
        Write-LzAwsVerbose "Verifying image in ECR"
        Write-Host "Verifying image in ECR..."
        try {
            $awsCommand = if ($IsWindows -or $env:OS -match "Windows") { "aws" } else { "aws.exe" }

            $verifyResult = & $awsCommand ecr describe-images `
                --profile $ProfileName `
                --repository-name $EcrRepositoryName `
                --region $Region `
                --image-ids imageTag=$ImageTag `
                --query 'imageDetails[0].[imageTags[0],imagePushedAt,imageSizeInBytes]' `
                --output table 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host ""
                Write-Host $verifyResult
            }
        }
        catch {
            Write-LzAwsVerbose "Warning: Could not verify image (non-critical): $($_.Exception.Message)"
        }

        Write-Host ""
        Write-Host "======================================"
        Write-Host "Successfully deployed Docker image!" -ForegroundColor Green
        Write-Host "Image URI: $FullImageUri"
        Write-Host "======================================"

        return $true
    }
    catch {
        Write-Host ($_.Exception.Message) -ForegroundColor Red
        return $false
    }
}
