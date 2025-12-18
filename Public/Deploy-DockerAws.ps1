<#
.SYNOPSIS
    Builds and deploys a Docker container to AWS ECR
.DESCRIPTION
    Builds a Docker container image and pushes it to AWS Elastic Container Registry (ECR).
    This cmdlet prepares the NuGet package cache, builds the Docker image, and pushes it to ECR.
    
    When run from AWSTemplates directory without -Path, uses the standard Service/Containers structure.
    When -Path is specified, uses that path to find the Dockerfile (can be relative or absolute).
    
    Automatically uses docker buildx with --platform linux/amd64 when not running on x86_64 Linux.
.PARAMETER ContainerName
    The name of the container to build and deploy (e.g., "ChatAppRunner").
    If not specified when using -Path, defaults to the folder name containing the Dockerfile.
.PARAMETER ImageTag
    The tag to apply to the Docker image. Defaults to "latest"
.PARAMETER External
    Optional path to a folder containing a Dockerfile outside the LazyMagic solution structure.
    Can be relative or absolute. When specified, the build context is the folder containing the Dockerfile.
    When specified, skips Sync-DockerPackages (assumes self-contained Dockerfile).
.EXAMPLE
    Deploy-DockerAws -ContainerName "ChatAppRunner"
    Builds and deploys the ChatAppRunner container from Service/Containers/ChatAppRunner
.EXAMPLE
    Deploy-DockerAws -ContainerName "ChatAppRunner" -ImageTag "v1.0.0"
    Builds and deploys the ChatAppRunner container with a custom version tag
.EXAMPLE
    Deploy-DockerAws -External ./Smartstore
    Builds from an external Smartstore folder, using "smartstore" as the container name
.EXAMPLE
    Deploy-DockerAws -External ./Smartstore -ContainerName "MyStore"
    Builds from an external Smartstore folder with a custom container name
.NOTES
    - Requires Docker Desktop to be running
    - Requires valid AWS credentials and appropriate permissions
    - When not using -Path, must be run from the Service/AWSTemplates directory
    - Uses systemconfig.yaml for AWS configuration
    - Automatically uses docker buildx for cross-platform builds (non-x86_64 to linux/amd64)
.OUTPUTS
    Boolean - Returns $true on success, $false on failure
#>
function Deploy-DockerAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$ContainerName,

        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$ImageTag = "latest",

        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$External
    )

    # Determine if we're using an external Dockerfile path
    $useExternalPath = -not [string]::IsNullOrEmpty($External)
    
    # If using external path, resolve it and derive ContainerName if not specified
    if ($useExternalPath) {
        # Resolve to absolute path
        $resolvedPath = Resolve-Path -Path $External -ErrorAction SilentlyContinue
        if (-not $resolvedPath) {
            # Path doesn't exist yet, try to resolve parent and construct
            $resolvedPath = Join-Path (Get-Location) $External
        } else {
            $resolvedPath = $resolvedPath.Path
        }
        
        # Verify the path exists and contains a Dockerfile
        if (-not (Test-Path $resolvedPath)) {
            throw "Path not found: $External (resolved to: $resolvedPath)"
        }
        
        $dockerfilePath = Join-Path $resolvedPath "Dockerfile"
        if (-not (Test-Path $dockerfilePath)) {
            throw "Dockerfile not found at: $dockerfilePath"
        }
        
        # If ContainerName not specified, derive from folder name
        if ([string]::IsNullOrEmpty($ContainerName)) {
            $ContainerName = Split-Path $resolvedPath -Leaf
        }
        
        # Build context is the folder containing the Dockerfile
        $buildContext = $resolvedPath
    } else {
        # Traditional mode - require ContainerName
        if ([string]::IsNullOrEmpty($ContainerName)) {
            throw "ContainerName is required when not using -Path parameter"
        }
    }

    Write-LzAwsVerbose "Starting Docker container deployment for '$ContainerName'"

    try {
        # Step 0: Determine if we need to use buildx for cross-platform build
        $useBuildx = $false
        if ($IsMacOS) {
            # macOS (ARM or Intel) targeting linux/amd64
            $useBuildx = $true
            Write-LzAwsVerbose "Detected macOS - will use docker buildx for linux/amd64 target"
        } elseif ($IsLinux) {
            # Check Linux architecture
            $arch = & uname -m 2>&1
            if ($arch -ne "x86_64") {
                $useBuildx = $true
                Write-LzAwsVerbose "Detected non-x86_64 Linux ($arch) - will use docker buildx for linux/amd64 target"
            }
        }
        # Windows Docker Desktop typically targets linux/amd64 by default
        
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

        # Step 2: Validate directory structure (only when not using external path)
        if (-not $useExternalPath) {
            Write-LzAwsVerbose "Validating AWSTemplates directory structure"

            # Check if we're in AWSTemplates folder
            $currentDir = Get-Location
            if ((Split-Path $currentDir -Leaf) -ne "AWSTemplates") {
                $errorMessage = @"
Error: Must be run from the AWSTemplates directory (or use -Path parameter)
Function: Deploy-DockerAws
Hints:
  - Navigate to the AWSTemplates directory
  - Current directory: $currentDir
  - Run: cd Service/AWSTemplates
  - Or use: Deploy-DockerAws -External ./path/to/dockerfile/folder
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
            
            # Build context for traditional mode is parent directory (Service)
            $buildContext = ".."
        } else {
            Write-LzAwsVerbose "Using external Dockerfile at: $dockerfilePath"
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
        if ($useExternalPath) {
            Write-Host "Dockerfile Path: $dockerfilePath"
            Write-Host "Build Context: $buildContext"
        }
        if ($useBuildx) {
            Write-Host "Build Mode: docker buildx (target: linux/amd64)"
        } else {
            Write-Host "Build Mode: docker build"
        }
        Write-Host "ECR Repository: $EcrRepositoryName"
        Write-Host "Full Image URI: $FullImageUri"
        Write-Host "AWS Profile: $ProfileName"
        Write-Host "AWS Region: $Region"
        Write-Host "======================================"

        # Step 5: Ensure ECR repository exists
        Write-LzAwsVerbose "Checking if ECR repository exists"
        Write-Host "Checking ECR repository..."

        $awsCommand = "aws"

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

        # Step 7: Synchronize Docker packages (skip for external Dockerfiles)
        if (-not $useExternalPath) {
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
        } else {
            Write-LzAwsVerbose "Skipping Sync-DockerPackages for external Dockerfile"
        }

        # Step 8: Build the Docker image
        Write-LzAwsVerbose "Building Docker image"
        Write-Host "Building Docker image '$ImageName'..."
        if ($useBuildx) {
            Write-Host "Using docker buildx for cross-platform build (target: linux/amd64)"
        }
        try {
            # Build command varies based on buildx requirement and path mode
            if ($useExternalPath) {
                # External path mode - Dockerfile path is absolute, context is the folder
                if ($useBuildx) {
                    $buildResult = docker buildx build --platform linux/amd64 -f $dockerfilePath -t $ImageName --load $buildContext 2>&1
                } else {
                    $buildResult = docker build -f $dockerfilePath -t $ImageName $buildContext 2>&1
                }
            } else {
                # Traditional mode - relative paths from AWSTemplates
                if ($useBuildx) {
                    $buildResult = docker buildx build --platform linux/amd64 -f $dockerfilePath --build-arg ContainerName=$ContainerName -t $ImageName --load $buildContext 2>&1
                } else {
                    $buildResult = docker build -f $dockerfilePath --build-arg ContainerName=$ContainerName -t $ImageName $buildContext 2>&1
                }
            }
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
  - If using buildx, ensure docker buildx is available: docker buildx version
"@
            if (-not $useExternalPath) {
                $errorMessage += "`n  - Try running: Sync-DockerPackages -ProjectPath `"Containers/$ContainerName/$ContainerName.csproj`""
            }
            $errorMessage += "`nError Details: $($_.Exception.Message)"
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
