<#
.SYNOPSIS
    Runs an ECS Fargate task and waits for completion
.DESCRIPTION
    Generalized helper that runs an ECS Fargate task, waits for it to stop,
    and checks the exit code. Used by Deploy-SystemAws (DB init) and
    Deploy-ServiceAws (config init) for ECS-based deployments.
.PARAMETER TaskFamily
    The ECS task definition family name (e.g., "ezra-db-init")
.PARAMETER ClusterArn
    The ECS cluster ARN to run the task on
.PARAMETER Subnets
    Comma-separated subnet IDs for the task's network configuration
.PARAMETER SecurityGroup
    Security group ID for the task's network configuration
.PARAMETER Description
    Human-readable description of what the task does (for log messages)
.EXAMPLE
    Invoke-EcsInitTask -TaskFamily "ezra-db-init" -ClusterArn $clusterArn `
        -Subnets "$subnet1,$subnet2" -SecurityGroup $sg -Description "database initialization"
.OUTPUTS
    System.Boolean - $true if task succeeded, $false if failed
#>
function Invoke-EcsInitTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFamily,

        [Parameter(Mandatory = $true)]
        [string]$ClusterArn,

        [Parameter(Mandatory = $true)]
        [string]$Subnets,

        [Parameter(Mandatory = $true)]
        [string]$SecurityGroup,

        [string]$Description = "initialization"
    )

    $Region = $script:Region
    $ProfileName = $script:ProfileName

    Write-Host "Running $Description task..." -ForegroundColor Cyan

    try {
        $taskArn = aws ecs run-task `
            --cluster $ClusterArn `
            --task-definition $TaskFamily `
            --launch-type FARGATE `
            --network-configuration "awsvpcConfiguration={subnets=[$Subnets],securityGroups=[$SecurityGroup],assignPublicIp=DISABLED}" `
            --region $Region `
            --profile $ProfileName `
            --query 'tasks[0].taskArn' --output text 2>&1

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($taskArn) -or $taskArn -eq "None") {
            Write-Host "Error: Failed to start $Description task" -ForegroundColor Red
            Write-LzAwsVerbose "run-task output: $taskArn"
            return $false
        }

        Write-Host "Task started: $taskArn" -ForegroundColor Gray
        Write-Host "Waiting for completion..." -ForegroundColor Gray

        aws ecs wait tasks-stopped `
            --cluster $ClusterArn `
            --tasks $taskArn `
            --region $Region `
            --profile $ProfileName 2>&1 | Out-Null

        $exitCode = aws ecs describe-tasks `
            --cluster $ClusterArn `
            --tasks $taskArn `
            --region $Region `
            --profile $ProfileName `
            --query 'tasks[0].containers[0].exitCode' --output text 2>&1

        if ($exitCode -eq "0") {
            Write-Host "Successfully completed $Description" -ForegroundColor Green
            return $true
        } else {
            Write-Host "$Description failed (exit code: $exitCode)" -ForegroundColor Red
            Write-LzAwsVerbose "Check CloudWatch logs for task family: $TaskFamily"
            return $false
        }
    }
    catch {
        Write-Host "Error during ${Description}: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}
