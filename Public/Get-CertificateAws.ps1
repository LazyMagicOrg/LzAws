<#
.SYNOPSIS
    Retrieves and installs a certificate from an EC2 instance
.DESCRIPTION
    Fetches the localhost.crt certificate from /opt/dev1/certs-local/ on a newly deployed
    EC2 instance using AWS Systems Manager (SSM), saves it locally, and optionally installs
    it to the system trust store.
.PARAMETER Name
    Optional. The name of the EC2 instance to target. If not specified, uses the first
    running EC2 instance found.
.PARAMETER OutputPath
    Optional. The path where the certificate file should be saved. Defaults to 'localhost.crt'
    in the current directory.
.PARAMETER NoInstall
    Optional switch. If specified, skips installing the certificate to the system trust store.
    By default, the certificate is installed to the system trust store.
    On macOS, adds to the System Keychain. On Windows, adds to the LocalMachine\Root store.
.EXAMPLE
    Get-CertificateAws
    Retrieves the certificate from the first running EC2 instance, saves it locally, and installs it
.EXAMPLE
    Get-CertificateAws -Name "my-instance"
    Retrieves the certificate from the specified EC2 instance and installs it
.EXAMPLE
    Get-CertificateAws -NoInstall
    Retrieves the certificate and saves it locally without installing
.EXAMPLE
    Get-CertificateAws -OutputPath "./certs/localhost.crt" -NoInstall
    Retrieves the certificate and saves to specified path without installing
.NOTES
    - Requires valid AWS credentials and appropriate permissions
    - EC2 instances must have SSM agent installed and running
    - Instances must have appropriate IAM role for SSM
    - Installing certificates requires administrator/sudo privileges
.OUTPUTS
    Boolean. Returns $true on success, $false on failure.
#>
function Get-CertificateAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        [string]$OutputPath = "localhost.crt",

        [Parameter(Mandatory=$false)]
        [switch]$NoInstall
    )

    Write-LzAwsVerbose "Starting certificate retrieval from EC2 instance"
    try {
        $SystemConfig = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region

        # Find target EC2 instance
        if ([string]::IsNullOrEmpty($Name)) {
            Write-LzAwsVerbose "No instance name specified, targeting first running instance"
            $InstancesJson = aws ec2 describe-instances `
                --filters "Name=instance-state-name,Values=running" `
                --query "Reservations[].Instances[].InstanceId" `
                --output json `
                --profile $ProfileName `
                --region $Region 2>&1

            if ($LASTEXITCODE -ne 0) {
                $errorMessage = @"
Error: Failed to query EC2 instances
Function: Get-CertificateAws
Hints:
  - Check if you have permission to describe EC2 instances
  - Verify your AWS credentials are valid
  - Ensure you have network connectivity to AWS
Error Details: $InstancesJson
"@
                throw $errorMessage
            }

            $InstanceIds = ($InstancesJson | Out-String) | ConvertFrom-Json
            if ($null -eq $InstanceIds -or $InstanceIds.Count -eq 0) {
                $errorMessage = @"
Error: No running EC2 instances found
Function: Get-CertificateAws
Hints:
  - Check if there are running EC2 instances in the region
  - Verify your AWS credentials have EC2 describe permissions
  - Ensure instances are in 'running' state
"@
                throw $errorMessage
            }
            # Handle both single instance (string) and multiple instances (array)
            if ($InstanceIds -is [string]) {
                $InstanceId = $InstanceIds
            } else {
                $InstanceId = $InstanceIds[0]
            }
            Write-LzAwsVerbose "Found running instance: $InstanceId"
        } else {
            Write-LzAwsVerbose "Targeting instance with name: $Name"
            $InstancesJson = aws ec2 describe-instances `
                --filters "Name=tag:Name,Values=$Name" "Name=instance-state-name,Values=running" `
                --query "Reservations[].Instances[].InstanceId" `
                --output json `
                --profile $ProfileName `
                --region $Region 2>&1

            if ($LASTEXITCODE -ne 0) {
                $errorMessage = @"
Error: Failed to query EC2 instance with name '$Name'
Function: Get-CertificateAws
Hints:
  - Check if you have permission to describe EC2 instances
  - Verify your AWS credentials are valid
  - Ensure you have network connectivity to AWS
Error Details: $InstancesJson
"@
                throw $errorMessage
            }

            $InstanceIds = ($InstancesJson | Out-String) | ConvertFrom-Json
            if ($null -eq $InstanceIds -or $InstanceIds.Count -eq 0) {
                $errorMessage = @"
Error: No running EC2 instance found with name '$Name'
Function: Get-CertificateAws
Hints:
  - Verify the instance name is correct
  - Check if the instance is in 'running' state
  - Ensure the instance has a 'Name' tag
"@
                throw $errorMessage
            }
            # Handle both single instance (string) and multiple instances (array)
            if ($InstanceIds -is [string]) {
                $InstanceId = $InstanceIds
            } else {
                $InstanceId = $InstanceIds[0]
            }
            Write-LzAwsVerbose "Found instance: $InstanceId"
        }

        # Retrieve certificate via SSM
        $Command = "cat /opt/dev1/certs-local/localhost.crt"
        Write-Host "Retrieving certificate from instance: $InstanceId" -ForegroundColor Cyan
        Write-LzAwsVerbose "Executing command: $Command"

        $SsmResultJson = aws ssm send-command `
            --instance-ids $InstanceId `
            --document-name "AWS-RunShellScript" `
            --parameters "commands=[`"$Command`"]" `
            --cloud-watch-output-config '{"CloudWatchLogGroupName":"/ec2/dev/ssm-commands","CloudWatchOutputEnabled":true}' `
            --output json `
            --profile $ProfileName `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: Failed to send SSM command to instance '$InstanceId'
Function: Get-CertificateAws
Hints:
  - Check if the instance has SSM agent installed and running
  - Verify the instance has an IAM role with SSM permissions
  - Ensure the instance is registered with SSM
Error Details: $SsmResultJson
"@
            throw $errorMessage
        }

        $SsmResult = $SsmResultJson | ConvertFrom-Json
        $CommandId = $SsmResult.Command.CommandId
        Write-LzAwsVerbose "Command sent with ID: $CommandId"

        # Wait for command to complete
        Write-LzAwsVerbose "Waiting for command to complete..."
        $MaxAttempts = 30
        $Attempt = 0
        $Status = "Pending"

        while ($Status -in @("Pending", "InProgress") -and $Attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds 2
            $Attempt++
            
            $InvocationJson = aws ssm get-command-invocation `
                --command-id $CommandId `
                --instance-id $InstanceId `
                --output json `
                --profile $ProfileName `
                --region $Region 2>&1

            if ($LASTEXITCODE -eq 0) {
                $Invocation = $InvocationJson | ConvertFrom-Json
                $Status = $Invocation.Status
                Write-LzAwsVerbose "Command status: $Status (attempt $Attempt/$MaxAttempts)"
            }
        }

        if ($Status -ne "Success") {
            if ($Status -in @("Pending", "InProgress")) {
                $errorMessage = @"
Error: Command timed out waiting for completion on instance '$InstanceId'
Function: Get-CertificateAws
Hints:
  - Check if the SSM agent is responsive on the instance
  - Verify network connectivity to the instance
  - Check AWS console for command status: $CommandId
"@
            } else {
                $ErrorOutput = $Invocation.StandardErrorContent
                $errorMessage = @"
Error: SSM command failed on instance '$InstanceId' with status '$Status'
Function: Get-CertificateAws
Hints:
  - Check if the certificate file exists at /opt/dev1/certs-local/localhost.crt
  - Verify the instance has read permissions on the certificate file
  - Ensure the certificate generation process completed successfully
Error Details: $ErrorOutput
"@
            }
            throw $errorMessage
        }

        # Extract certificate content
        $CertificateContent = $Invocation.StandardOutputContent
        if ([string]::IsNullOrEmpty($CertificateContent)) {
            $errorMessage = @"
Error: Certificate file is empty or not found
Function: Get-CertificateAws
Hints:
  - Check if the certificate file exists at /opt/dev1/certs-local/localhost.crt
  - Verify the certificate generation process completed successfully
  - Ensure the file has content and is readable
"@
            throw $errorMessage
        }

        Write-LzAwsVerbose "Certificate content retrieved successfully"

        # Save certificate to file
        try {
            Set-Content -Path $OutputPath -Value $CertificateContent -NoNewline
            Write-Host "Certificate saved to: $OutputPath" -ForegroundColor Green
        }
        catch {
            $errorMessage = @"
Error: Failed to save certificate file
Function: Get-CertificateAws
Hints:
  - Check if you have write permissions in the target directory
  - Verify sufficient disk space
  - Ensure the output path is valid
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Install certificate unless skipped
        if (-not $NoInstall) {
            Write-Host "Installing certificate to system trust store..." -ForegroundColor Cyan
            
            if ($IsMacOS) {
                Write-Host "  Platform: macOS - installing to System Keychain" -ForegroundColor Cyan
                Write-Host "  Running: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $OutputPath" -ForegroundColor Gray
                $InstallResult = sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $OutputPath 2>&1
                $ExitCode = $LASTEXITCODE
                Write-LzAwsVerbose "security command exit code: $ExitCode"
                if ($ExitCode -ne 0) {
                    $errorMessage = @"
Error: Failed to install certificate to macOS Keychain (exit code: $ExitCode)
Function: Get-CertificateAws
Hints:
  - Ensure you have administrator privileges (sudo access)
  - Check if the certificate file is valid
  - Try running the command manually: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $OutputPath
Error Details: $InstallResult
"@
                    throw $errorMessage
                }
                Write-Host "Certificate successfully installed to macOS System Keychain" -ForegroundColor Green
            }
            elseif ($IsWindows) {
                Write-Host "  Platform: Windows - installing to LocalMachine\Root store" -ForegroundColor Cyan
                try {
                    $CertResult = Import-Certificate -FilePath $OutputPath -CertStoreLocation Cert:\LocalMachine\Root
                    Write-Host "  Thumbprint: $($CertResult.Thumbprint)" -ForegroundColor Gray
                    Write-Host "Certificate successfully installed to Windows LocalMachine\Root store" -ForegroundColor Green
                }
                catch {
                    $errorMessage = @"
Error: Failed to install certificate to Windows certificate store
Function: Get-CertificateAws
Hints:
  - Ensure you are running PowerShell as Administrator
  - Check if the certificate file is valid
  - Try running: Import-Certificate -FilePath $OutputPath -CertStoreLocation Cert:\LocalMachine\Root
Error Details: $($_.Exception.Message)
"@
                    throw $errorMessage
                }
            }
            else {
                Write-Host "  Platform: Linux/Unknown - automatic installation not supported" -ForegroundColor Yellow
                Write-Host "  Please install the certificate manually to your system trust store" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "Skipping certificate installation (-NoInstall specified)" -ForegroundColor Yellow
        }

        Write-Host "Certificate retrieval completed successfully" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
