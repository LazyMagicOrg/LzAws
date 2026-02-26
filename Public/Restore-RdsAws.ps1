<#
.SYNOPSIS
    Restores an RDS instance from a snapshot using the rename-swap technique
.DESCRIPTION
    Replaces the running RDS instance ({SystemKey}-db) with data from a
    specified snapshot, using the AWS RDS rename technique. This avoids
    redeploying any CloudFormation stacks.

    Steps performed:
    1. Verifies the current RDS instance exists and is available
    2. Verifies the snapshot exists
    3. Pre-flight checks for leftover instances from previous attempts
    4. Restores the snapshot to a temporary instance ({SystemKey}-db-restored)
    5. Waits for the restored instance to become available
    6. Renames the current instance to {SystemKey}-db-old
    7. Renames the restored instance to {SystemKey}-db
    8. Re-enables Secrets Manager managed credentials on the restored instance
    9. Prints post-restore guidance (Deploy-DataAws, Deploy-AuthsAws)

    WARNING: This is a destructive operation. The renamed original instance
    will have a different endpoint. Connected services will be interrupted.
.PARAMETER DbSnapshotIdentifier
    Mandatory. The RDS snapshot identifier (or ARN for automated/shared
    snapshots) to restore from.
.PARAMETER SkipConfirmation
    Optional switch to bypass the interactive confirmation prompt.
    Use with caution in automated scripts.
.EXAMPLE
    Restore-RdsAws -DbSnapshotIdentifier "my-manual-snapshot-2024-01-15"
    Restores the snapshot and swaps it into place as {SystemKey}-db
.EXAMPLE
    Restore-RdsAws -DbSnapshotIdentifier "my-snapshot" -SkipConfirmation
    Performs the restore without interactive confirmation
.NOTES
    - Requires valid AWS credentials and appropriate RDS permissions
    - The original instance is renamed to {SystemKey}-db-old (not deleted)
    - Each rename causes a brief reboot of the affected instance
    - The endpoint hostname changes on rename, breaking existing connections
    - After verification, manually delete {SystemKey}-db-old
.OUTPUTS
    Boolean - $true on success, $false on failure
#>
function Restore-RdsAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DbSnapshotIdentifier,

        [Parameter(Mandatory=$false)]
        [switch]$SkipConfirmation
    )

    Write-LzAwsVerbose "Restore-RdsAws"

    try {
        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $SystemKey = $Config.SystemKey

        $DbInstanceId = "$SystemKey-db"
        $RestoredInstanceId = "$SystemKey-db-restored"
        $OldInstanceId = "$SystemKey-db-old"

        # =====================================================================
        # Step 1: Verify the current RDS instance exists and is available
        # =====================================================================
        Write-Host "Step 1: Verifying current RDS instance '$DbInstanceId'..." -ForegroundColor Cyan
        Write-LzAwsVerbose "Checking for existing RDS instance: $DbInstanceId"

        $dbJson = aws rds describe-db-instances `
            --db-instance-identifier $DbInstanceId `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: RDS instance '$DbInstanceId' not found
Function: Restore-RdsAws
Hints:
  - Verify the SystemKey in systemconfig.yaml is correct (current: $SystemKey)
  - Ensure the RDS instance exists: aws rds describe-db-instances --db-instance-identifier $DbInstanceId --profile $ProfileName --region $Region
  - The instance may have been deleted or never created
"@
            throw $errorMessage
        }

        $dbInfo = ($dbJson | ConvertFrom-Json).DBInstances[0]
        $dbStatus = $dbInfo.DBInstanceStatus

        if ($dbStatus -ne "available") {
            $errorMessage = @"
Error: RDS instance '$DbInstanceId' is not available (current status: $dbStatus)
Function: Restore-RdsAws
Hints:
  - Wait for the instance to reach 'available' status
  - Check the AWS RDS console for the instance status
  - The instance may be in the middle of a modification or maintenance window
"@
            throw $errorMessage
        }

        # Capture settings from the original instance for the restore
        $OriginalVpcSecurityGroupIds = ($dbInfo.VpcSecurityGroups | ForEach-Object { $_.VpcSecurityGroupId }) -join ' '
        $OriginalDbSubnetGroupName = $dbInfo.DBSubnetGroup.DBSubnetGroupName
        $OriginalDbParameterGroupName = ($dbInfo.DBParameterGroups | Select-Object -First 1).DBParameterGroupName
        $OriginalEndpoint = $dbInfo.Endpoint.Address

        Write-Host "  Instance: $DbInstanceId" -ForegroundColor Green
        Write-Host "  Status: $dbStatus" -ForegroundColor Green
        Write-Host "  Endpoint: $OriginalEndpoint" -ForegroundColor Green
        Write-LzAwsVerbose "VPC Security Groups: $OriginalVpcSecurityGroupIds"
        Write-LzAwsVerbose "DB Subnet Group: $OriginalDbSubnetGroupName"
        Write-LzAwsVerbose "Parameter Group: $OriginalDbParameterGroupName"

        # =====================================================================
        # Step 2: Verify the snapshot exists
        # =====================================================================
        Write-Host "Step 2: Verifying snapshot '$DbSnapshotIdentifier'..." -ForegroundColor Cyan
        Write-LzAwsVerbose "Verifying snapshot: $DbSnapshotIdentifier"

        $snapshotJson = aws rds describe-db-snapshots `
            --db-snapshot-identifier $DbSnapshotIdentifier `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            # Try as a shared/automated snapshot (by ARN)
            $snapshotJson = aws rds describe-db-snapshots `
                --db-snapshot-identifier $DbSnapshotIdentifier `
                --include-shared `
                --profile $ProfileName `
                --region $Region `
                --output json 2>&1
        }

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: DB snapshot '$DbSnapshotIdentifier' not found
Function: Restore-RdsAws
Hints:
  - Verify the snapshot identifier or ARN is correct
  - Ensure the snapshot is in the same region ($Region)
  - For shared snapshots, verify the snapshot has been shared with this account
  - Use 'aws rds describe-db-snapshots --profile $ProfileName --region $Region' to list available snapshots
"@
            throw $errorMessage
        }

        $snapshotInfo = ($snapshotJson | ConvertFrom-Json).DBSnapshots[0]
        Write-Host "  Snapshot: $DbSnapshotIdentifier" -ForegroundColor Green
        Write-Host "  Snapshot Status: $($snapshotInfo.Status)" -ForegroundColor Green
        Write-Host "  Engine: $($snapshotInfo.Engine) $($snapshotInfo.EngineVersion)" -ForegroundColor Green

        # =====================================================================
        # Step 3: Pre-flight check for leftover instances
        # =====================================================================
        Write-Host "Step 3: Pre-flight checks..." -ForegroundColor Cyan

        # Check if {SystemKey}-db-restored already exists
        $restoredCheck = aws rds describe-db-instances `
            --db-instance-identifier $RestoredInstanceId `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $errorMessage = @"
Error: Instance '$RestoredInstanceId' already exists
Function: Restore-RdsAws
Hints:
  - A previous restore may not have completed cleanly
  - Delete the leftover instance: aws rds delete-db-instance --db-instance-identifier $RestoredInstanceId --skip-final-snapshot --profile $ProfileName --region $Region
  - Wait for deletion to complete, then re-run Restore-RdsAws
"@
            throw $errorMessage
        }

        # Check if {SystemKey}-db-old already exists
        $oldCheck = aws rds describe-db-instances `
            --db-instance-identifier $OldInstanceId `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $errorMessage = @"
Error: Instance '$OldInstanceId' already exists
Function: Restore-RdsAws
Hints:
  - A previous restore left the old instance behind
  - Delete it if the previous restore was successful: aws rds delete-db-instance --db-instance-identifier $OldInstanceId --skip-final-snapshot --profile $ProfileName --region $Region
  - Wait for deletion to complete, then re-run Restore-RdsAws
"@
            throw $errorMessage
        }

        Write-Host "  No leftover instances found" -ForegroundColor Green

        # =====================================================================
        # Step 4: Confirmation prompt
        # =====================================================================
        Write-Host ""
        Write-Host "======================================" -ForegroundColor Yellow
        Write-Host "RDS Restore Summary" -ForegroundColor Yellow
        Write-Host "======================================" -ForegroundColor Yellow
        Write-Host "Source snapshot:   $DbSnapshotIdentifier"
        Write-Host "Current instance:  $DbInstanceId (will be renamed to $OldInstanceId)"
        Write-Host "Restored instance: $RestoredInstanceId (will be renamed to $DbInstanceId)"
        Write-Host ""
        Write-Host "WARNING: This operation will:" -ForegroundColor Red
        Write-Host "  - Restore the snapshot to a new temporary instance" -ForegroundColor Red
        Write-Host "  - Rename the current '$DbInstanceId' to '$OldInstanceId'" -ForegroundColor Red
        Write-Host "  - Rename the restored instance to '$DbInstanceId'" -ForegroundColor Red
        Write-Host "  - Each rename causes a brief reboot" -ForegroundColor Red
        Write-Host "  - Connected services will be interrupted" -ForegroundColor Red
        Write-Host "======================================" -ForegroundColor Yellow

        if (-not $SkipConfirmation) {
            $confirmation = Read-Host "Type 'yes' to proceed with the restore"
            if ($confirmation -ne 'yes') {
                Write-Host "Restore cancelled by user" -ForegroundColor Yellow
                return $false
            }
        }

        # =====================================================================
        # Step 5: Restore snapshot to temporary instance
        # =====================================================================
        Write-Host ""
        Write-Host "Step 5: Restoring snapshot to '$RestoredInstanceId'..." -ForegroundColor Cyan
        Write-Host "  This may take 10-30 minutes depending on snapshot size." -ForegroundColor Yellow
        Write-LzAwsVerbose "Restoring snapshot $DbSnapshotIdentifier to $RestoredInstanceId"

        $restoreResult = aws rds restore-db-instance-from-db-snapshot `
            --db-instance-identifier $RestoredInstanceId `
            --db-snapshot-identifier $DbSnapshotIdentifier `
            --db-subnet-group-name $OriginalDbSubnetGroupName `
            --vpc-security-group-ids $OriginalVpcSecurityGroupIds `
            --no-multi-az `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: Failed to restore snapshot to '$RestoredInstanceId'
Function: Restore-RdsAws
Hints:
  - Verify you have rds:RestoreDBInstanceFromDBSnapshot permission
  - Check the snapshot is in 'available' state
  - Ensure the DB subnet group '$OriginalDbSubnetGroupName' still exists
  - Verify the VPC security groups still exist: $OriginalVpcSecurityGroupIds
  - Check AWS RDS console for detailed error messages
Error Details: $($restoreResult | Out-String)
"@
            throw $errorMessage
        }

        Write-Host "  Restore initiated successfully" -ForegroundColor Green

        # =====================================================================
        # Step 6: Wait for restored instance to become available
        # =====================================================================
        Write-Host "Step 6: Waiting for '$RestoredInstanceId' to become available..." -ForegroundColor Cyan
        Write-LzAwsVerbose "Waiting for restored instance to become available (this may take a while)"

        # Use aws rds wait which polls every 30 seconds for up to ~30 minutes
        $waitResult = aws rds wait db-instance-available `
            --db-instance-identifier $RestoredInstanceId `
            --profile $ProfileName `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            # The wait timed out or failed. Try manual polling for an additional 30 minutes.
            Write-Host "  Initial wait timed out. Continuing to poll..." -ForegroundColor Yellow
            $maxRetries = 60
            $retryCount = 0
            $instanceAvailable = $false

            while ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 30
                $retryCount++

                $statusJson = aws rds describe-db-instances `
                    --db-instance-identifier $RestoredInstanceId `
                    --query "DBInstances[0].DBInstanceStatus" `
                    --output text `
                    --profile $ProfileName `
                    --region $Region 2>&1

                if ($LASTEXITCODE -eq 0 -and $statusJson -eq "available") {
                    $instanceAvailable = $true
                    break
                }

                Write-LzAwsVerbose "Instance status: $statusJson (attempt $retryCount/$maxRetries)"

                if ($retryCount % 10 -eq 0) {
                    Write-Host "  Still waiting... (status: $statusJson, attempt $retryCount/$maxRetries)" -ForegroundColor Yellow
                }
            }

            if (-not $instanceAvailable) {
                $errorMessage = @"
Error: Restored instance '$RestoredInstanceId' did not become available within the timeout period
Function: Restore-RdsAws
Hints:
  - Check the RDS console for the instance status
  - The instance may still be coming up — check status with:
    aws rds describe-db-instances --db-instance-identifier $RestoredInstanceId --query "DBInstances[0].DBInstanceStatus" --profile $ProfileName --region $Region
  - If the instance is available, re-run the rename steps manually
  - To clean up: aws rds delete-db-instance --db-instance-identifier $RestoredInstanceId --skip-final-snapshot --profile $ProfileName --region $Region
"@
                throw $errorMessage
            }
        }

        Write-Host "  Instance '$RestoredInstanceId' is now available" -ForegroundColor Green

        # =====================================================================
        # Step 7: Rename current instance to {SystemKey}-db-old
        # =====================================================================
        Write-Host "Step 7: Renaming '$DbInstanceId' -> '$OldInstanceId'..." -ForegroundColor Cyan
        Write-LzAwsVerbose "Renaming $DbInstanceId to $OldInstanceId"

        $renameResult = aws rds modify-db-instance `
            --db-instance-identifier $DbInstanceId `
            --new-db-instance-identifier $OldInstanceId `
            --apply-immediately `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: Failed to rename '$DbInstanceId' to '$OldInstanceId'
Function: Restore-RdsAws
Hints:
  - Verify the instance is in 'available' state
  - Ensure '$OldInstanceId' does not already exist
  - Check you have rds:ModifyDBInstance permission
  - The restored instance '$RestoredInstanceId' still exists and may need manual cleanup
Error Details: $($renameResult | Out-String)
"@
            throw $errorMessage
        }

        Write-Host "  Rename initiated. Waiting for '$OldInstanceId' to become available..." -ForegroundColor Green
        Write-LzAwsVerbose "Waiting for renamed instance $OldInstanceId to become available"

        $waitResult = aws rds wait db-instance-available `
            --db-instance-identifier $OldInstanceId `
            --profile $ProfileName `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: Timed out waiting for '$OldInstanceId' to become available after rename
Function: Restore-RdsAws
Hints:
  - Check the RDS console for instance status
  - The rename may still be in progress
  - The restored instance '$RestoredInstanceId' still needs to be renamed to '$DbInstanceId'
  - You may need to complete the rename manually:
    aws rds modify-db-instance --db-instance-identifier $RestoredInstanceId --new-db-instance-identifier $DbInstanceId --apply-immediately --profile $ProfileName --region $Region
"@
            throw $errorMessage
        }

        Write-Host "  Rename complete: '$OldInstanceId' is available" -ForegroundColor Green

        # =====================================================================
        # Step 8: Rename restored instance to {SystemKey}-db
        # =====================================================================
        Write-Host "Step 8: Renaming '$RestoredInstanceId' -> '$DbInstanceId'..." -ForegroundColor Cyan
        Write-LzAwsVerbose "Renaming $RestoredInstanceId to $DbInstanceId"

        $renameResult = aws rds modify-db-instance `
            --db-instance-identifier $RestoredInstanceId `
            --new-db-instance-identifier $DbInstanceId `
            --apply-immediately `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: Failed to rename '$RestoredInstanceId' to '$DbInstanceId'
Function: Restore-RdsAws
Hints:
  - The original instance was already renamed to '$OldInstanceId'
  - The restored instance '$RestoredInstanceId' still exists
  - You may need to complete this rename manually:
    aws rds modify-db-instance --db-instance-identifier $RestoredInstanceId --new-db-instance-identifier $DbInstanceId --apply-immediately --profile $ProfileName --region $Region
  - If '$DbInstanceId' already exists (race condition), wait and retry
Error Details: $($renameResult | Out-String)
"@
            throw $errorMessage
        }

        Write-Host "  Rename initiated. Waiting for '$DbInstanceId' to become available..." -ForegroundColor Green
        Write-LzAwsVerbose "Waiting for renamed instance $DbInstanceId to become available"

        $waitResult = aws rds wait db-instance-available `
            --db-instance-identifier $DbInstanceId `
            --profile $ProfileName `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: Timed out waiting for '$DbInstanceId' to become available after rename
Function: Restore-RdsAws
Hints:
  - Check the RDS console for instance status
  - The rename may still be in progress
  - The old instance is now '$OldInstanceId'
  - Check status: aws rds describe-db-instances --db-instance-identifier $DbInstanceId --profile $ProfileName --region $Region
"@
            throw $errorMessage
        }

        Write-Host "  Rename complete: '$DbInstanceId' is available" -ForegroundColor Green

        # =====================================================================
        # Step 9: Re-enable Secrets Manager managed credentials
        # =====================================================================
        Write-Host "Step 9: Re-enabling Secrets Manager managed credentials on '$DbInstanceId'..." -ForegroundColor Cyan
        Write-LzAwsVerbose "Enabling manage-master-user-password on $DbInstanceId"

        $managePwResult = aws rds modify-db-instance `
            --db-instance-identifier $DbInstanceId `
            --manage-master-user-password `
            --apply-immediately `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Warning: Failed to enable managed credentials. You may need to do this manually:" -ForegroundColor Yellow
            Write-Host "  aws rds modify-db-instance --db-instance-identifier $DbInstanceId --manage-master-user-password --apply-immediately --profile $ProfileName --region $Region" -ForegroundColor White
            Write-LzAwsVerbose "Error details: $($managePwResult | Out-String)"
        } else {
            Write-Host "  Managed credentials enabled. Waiting for modification to apply..." -ForegroundColor Green

            $waitResult = aws rds wait db-instance-available `
                --db-instance-identifier $DbInstanceId `
                --profile $ProfileName `
                --region $Region 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Warning: Timed out waiting for managed credentials modification. Check the RDS console." -ForegroundColor Yellow
            } else {
                # Verify the new secret was created
                $verifyJson = aws rds describe-db-instances `
                    --db-instance-identifier $DbInstanceId `
                    --query "DBInstances[0].MasterUserSecret.SecretArn" `
                    --output text `
                    --profile $ProfileName `
                    --region $Region 2>&1

                if ($LASTEXITCODE -eq 0 -and $verifyJson -ne 'None' -and -not [string]::IsNullOrWhiteSpace($verifyJson)) {
                    Write-Host "  New master secret ARN: $verifyJson" -ForegroundColor Green
                } else {
                    Write-Host "  Warning: Could not verify new master secret. Check the RDS console." -ForegroundColor Yellow
                }
            }
        }

        # =====================================================================
        # Step 10: Post-restore guidance
        # =====================================================================
        Write-Host ""
        Write-Host "======================================" -ForegroundColor Green
        Write-Host "RDS Restore Completed Successfully!" -ForegroundColor Green
        Write-Host "======================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "New active instance: $DbInstanceId" -ForegroundColor Green
        Write-Host "Old instance:        $OldInstanceId (still running)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "=== Post-Restore Steps ===" -ForegroundColor Yellow
        Write-Host "1. Run Deploy-DataAws to update the data stack with the new secret ARN" -ForegroundColor White
        Write-Host ""
        Write-Host "2. Run Deploy-AuthsAws to update Keycloak with the new DB credentials" -ForegroundColor White
        Write-Host ""
        Write-Host "3. Restart any other connected services (ECS tasks, Lambda functions, etc.)" -ForegroundColor White
        Write-Host ""
        Write-Host "4. When you are satisfied the restore is correct, delete the old instance:" -ForegroundColor White
        Write-Host "   aws rds delete-db-instance --db-instance-identifier $OldInstanceId --skip-final-snapshot --profile $ProfileName --region $Region" -ForegroundColor White
        Write-Host ""
        Write-Host "   Or take a final snapshot before deleting:" -ForegroundColor White
        Write-Host "   aws rds delete-db-instance --db-instance-identifier $OldInstanceId --final-db-snapshot-identifier ${OldInstanceId}-final --profile $ProfileName --region $Region" -ForegroundColor White
        Write-Host ""
    }
    catch {
        Write-Host ($_.Exception.Message) -ForegroundColor Red
        return $false
    }

    Write-Host "Restore-RdsAws completed"
    return $true
}
