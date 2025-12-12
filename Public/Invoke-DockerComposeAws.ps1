<#
.SYNOPSIS
    Invokes docker compose on EC2 instances via SSM
.DESCRIPTION
    Executes 'docker compose up' on one or all EC2 instances using AWS Systems Manager (SSM).
    The command runs in the /opt/dev1/ec2-setup directory on the target instance(s).
.PARAMETER Name
    Optional. The name of the EC2 instance to target. If not specified, the command
    runs on all EC2 instances that are SSM-managed.
.EXAMPLE
    Invoke-DockerComposeAws
    Runs docker compose up on all EC2 instances
.EXAMPLE
    Invoke-DockerComposeAws -Name "my-instance"
    Runs docker compose up on the specified EC2 instance
.NOTES
    - Requires valid AWS credentials and appropriate permissions
    - EC2 instances must have SSM agent installed and running
    - Instances must have appropriate IAM role for SSM
.OUTPUTS
    Boolean. Returns $true on success, $false on failure.
#>
function Invoke-DockerComposeAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Name
    )

    Write-LzAwsVerbose "Starting docker compose invocation via SSM"
    try {
        $SystemConfig = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region

        # Build instance filter based on Name parameter
        if ([string]::IsNullOrEmpty($Name)) {
            Write-LzAwsVerbose "No instance name specified, targeting all running instances"
            $InstancesJson = aws ec2 describe-instances `
                --filters "Name=instance-state-name,Values=running" `
                --query "Reservations[].Instances[].InstanceId" `
                --output json `
                --profile $ProfileName `
                --region $Region 2>&1

            if ($LASTEXITCODE -ne 0) {
                $errorMessage = @"
Error: Failed to query EC2 instances
Function: Invoke-DockerComposeAws
Hints:
  - Check if you have permission to describe EC2 instances
  - Verify your AWS credentials are valid
  - Ensure you have network connectivity to AWS
Error Details: $InstancesJson
"@
                throw $errorMessage
            }

            $InstanceIds = $InstancesJson | ConvertFrom-Json
            if ($InstanceIds.Count -eq 0) {
                $errorMessage = @"
Error: No running EC2 instances found
Function: Invoke-DockerComposeAws
Hints:
  - Check if there are running EC2 instances in the region
  - Verify your AWS credentials have EC2 describe permissions
  - Ensure instances are in 'running' state
"@
                throw $errorMessage
            }
            Write-LzAwsVerbose "Found $($InstanceIds.Count) running instance(s)"
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
Function: Invoke-DockerComposeAws
Hints:
  - Check if you have permission to describe EC2 instances
  - Verify your AWS credentials are valid
  - Ensure you have network connectivity to AWS
Error Details: $InstancesJson
"@
                throw $errorMessage
            }

            $InstanceIds = $InstancesJson | ConvertFrom-Json
            if ($InstanceIds.Count -eq 0) {
                $errorMessage = @"
Error: No running EC2 instance found with name '$Name'
Function: Invoke-DockerComposeAws
Hints:
  - Verify the instance name is correct
  - Check if the instance is in 'running' state
  - Ensure the instance has a 'Name' tag
"@
                throw $errorMessage
            }
            Write-LzAwsVerbose "Found instance: $($InstanceIds[0])"
        }

        # Execute docker compose via SSM
        $Command = "cd /opt/dev1/compose && docker compose up -d"
        Write-LzAwsVerbose "Executing command: $Command"

        foreach ($InstanceId in $InstanceIds) {
            Write-Host "Sending command to instance: $InstanceId" -ForegroundColor Cyan
            
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
Function: Invoke-DockerComposeAws
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

            if ($Status -eq "Success") {
                Write-Host "Successfully executed docker compose on instance: $InstanceId" -ForegroundColor Green
                if (-not [string]::IsNullOrEmpty($Invocation.StandardOutputContent)) {
                    Write-LzAwsVerbose "Command output: $($Invocation.StandardOutputContent)"
                }
            } elseif ($Status -in @("Pending", "InProgress")) {
                Write-Host "Command timed out waiting for completion on instance: $InstanceId" -ForegroundColor Yellow
                Write-Host "Command ID: $CommandId - check AWS console for status" -ForegroundColor Yellow
            } else {
                $ErrorOutput = $Invocation.StandardErrorContent
                $errorMessage = @"
Error: SSM command failed on instance '$InstanceId' with status '$Status'
Function: Invoke-DockerComposeAws
Hints:
  - Check if docker is installed on the instance
  - Verify the /opt/dev1/ec2-setup directory exists
  - Ensure docker-compose.yml is present in the directory
  - Check instance logs for more details
Error Details: $ErrorOutput
"@
                throw $errorMessage
            }
        }

        Write-Host "Docker compose invocation completed" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
