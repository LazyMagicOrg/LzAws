<#
.SYNOPSIS
    Opens SSH tunnels to an EC2 instance for port forwarding
.DESCRIPTION
    Establishes SSH port forwarding tunnels to an EC2 instance using AWS SSM.
    This script uses the AWS SSM Session Manager to proxy SSH connections,
    eliminating the need for direct SSH access or bastion hosts.
    
    The EC2 instance ID and services to forward are read from the Integrations
    section in systemconfig.yaml. Assumes AWS SSO login has already been completed.
.PARAMETER None
    This cmdlet does not accept parameters directly, but reads from system configuration
.EXAMPLE
    Open-TunnelAws
    Opens SSH tunnels based on Integrations configuration in systemconfig.yaml
.NOTES
    - Requires AWS CLI and Session Manager plugin installed
    - Requires valid AWS SSO session (run: aws sso login --profile <profile>)
    - Requires SSH client installed
    - EC2 instance must have SSM agent running and proper IAM permissions
.OUTPUTS
    Returns $true on success, $false on error
#>
function Open-TunnelAws {
    [CmdletBinding()]
    param()

    Write-LzAwsVerbose "Open-TunnelAws"

    try {
        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config

        # Validate Integrations configuration exists
        if (-not $Config.Integrations) {
            $errorMessage = @"
Error: Integrations configuration not found in systemconfig.yaml
Function: Open-TunnelAws
Hints:
  - Add an 'Integrations' section to your systemconfig.yaml file
  - Include 'InstanceId' with your EC2 instance ID
  - Include 'Services' dictionary with service configurations
  - Example:
    Integrations:
      InstanceId: "i-0123456789abcdef0"
      Services:
        database:
          Port: 5432
          Host: "localhost"
          DockerName: "postgres"
          Scheme: "tcp"
          Description: "PostgreSQL"
"@
            throw $errorMessage
        }

        $InstanceId = $Config.Integrations.InstanceId
        if ([string]::IsNullOrWhiteSpace($InstanceId)) {
            $errorMessage = @"
Error: InstanceId not specified in Integrations configuration
Function: Open-TunnelAws
Hints:
  - Add 'InstanceId' to the Integrations section in systemconfig.yaml
  - Example: InstanceId: "i-0123456789abcdef0"
  - You can find your instance ID in the AWS EC2 console
"@
            throw $errorMessage
        }

        $Services = $Config.Integrations.Services
        if (-not $Services -or $Services.Keys.Count -eq 0) {
            $errorMessage = @"
Error: No services specified in Integrations configuration
Function: Open-TunnelAws
Hints:
  - Add 'Services' dictionary to the Integrations section in systemconfig.yaml
  - Each service entry should be keyed by service name with 'Port' and optionally 'Description'
  - Example:
    Services:
      database:
        Port: 5432
        Host: "localhost"
        DockerName: "postgres"
        Scheme: "tcp"
        Description: "PostgreSQL"
"@
            throw $errorMessage
        }

        # Build the SSH command with port forwarding arguments
        $PortForwardArgs = @()
        Write-Host "Configuring port forwards:"
        foreach ($serviceName in $Services.Keys) {
            $serviceConfig = $Services[$serviceName]
            $port = $serviceConfig.Port
            $description = $serviceConfig.Description
            if ($description) {
                Write-Host "  - $serviceName (Port $port) : $description"
            } else {
                Write-Host "  - $serviceName (Port $port)"
            }
            $PortForwardArgs += "-L"
            $PortForwardArgs += "${port}:localhost:${port}"
        }

        # Build the ProxyCommand for AWS SSM
        $ProxyCommand = "aws ssm start-session --target $InstanceId --document-name AWS-StartSSHSession --parameters portNumber=22 --profile $ProfileName --region $Region"

        Write-Host "Opening SSH tunnel to EC2 instance: $InstanceId"
        Write-Host "Using AWS profile: $ProfileName, Region: $Region"
        Write-Host "Press Ctrl+C to close the tunnel"

        # Execute SSH with port forwarding
        # -N: Do not execute remote command (just forward ports)
        # -o ProxyCommand: Use AWS SSM as the proxy
        # -o StrictHostKeyChecking=accept-new: Auto-accept new host keys
        $sshArgs = @(
            "-N"
            "-o", "ProxyCommand=$ProxyCommand"
            "-o", "StrictHostKeyChecking=accept-new"
            "-o", "User=ec2-user"
        ) + $PortForwardArgs + @($InstanceId)

        & ssh @sshArgs

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $errorMessage = @"
Error: SSH tunnel failed with exit code $exitCode
Function: Open-TunnelAws
Hints:
  - Ensure you are logged in: aws sso login --profile $ProfileName
  - Verify the EC2 instance ID is correct: $InstanceId
  - Check that the EC2 instance is running and has SSM agent installed
  - Verify your IAM permissions allow SSM session access
  - Ensure the AWS Session Manager plugin is installed
"@
            throw $errorMessage
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }

    Write-Host "Open-TunnelAws completed"
    return $true
}
