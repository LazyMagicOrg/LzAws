function Create-DynamoDbTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )
    try {
        Write-LzAwsVerbose "Starting DynamoDB table creation"

        $SystemConfig = Get-SystemConfig
        # Get-SystemConfig already handles error propagation

        $Region = $SystemConfig.Region
        $ProfileName = $SystemConfig.ProfileName

        # Check if table exists
        try {
            $ExistingTable = Get-DDBTable -TableName $TableName -Region $Region -ErrorAction SilentlyContinue -ProfileName $ProfileName
            if ($ExistingTable) {
                Write-LzAwsVerbose "Table '$TableName' already exists."
                return
            }
        }
        catch {
            # If the error is "Table not found", that's expected and we can continue
            if ($_.Exception.Message -like "*Table: $TableName not found*") {
                Write-LzAwsVerbose "Table '$TableName' does not exist, proceeding with creation."
            }
            else {
                Write-Host "Error: Failed to check if table exists"
                Write-Host "Hints:"
                Write-Host "  - Check if you have permission to read DynamoDB tables"
                Write-Host "  - Verify AWS credentials are valid"
                Write-Host "  - Ensure the region is correct"
                Write-Host "Error Details: $($_.Exception.Message)"
                Write-Error "Failed to check if table exists: $($_.Exception.Message)" -ErrorAction Stop
            }
        }

        # Create a table schema compatible with the LazyMagic DynamoDb library
        # This library provides an entity abstraction with CRUDL support for DynamoDb
        try {
            $Schema = New-DDBTableSchema
            $Schema | Add-DDBKeySchema -KeyName "PK" -KeyDataType "S" -KeyType "HASH"
            $Schema | Add-DDBKeySchema -KeyName "SK" -KeyDataType "S" -KeyType "RANGE"
            $Schema | Add-DDBIndexSchema -IndexName "PK-SK1-Index" -RangeKeyName "SK1" -RangeKeyDataType "S" -ProjectionType "include" -NonKeyAttribute "Status", "UpdateUtcTick", "CreateUtcTick", "General"
            $Schema | Add-DDBIndexSchema -IndexName "PK-SK2-Index" -RangeKeyName "SK2" -RangeKeyDataType "S" -ProjectionType "include" -NonKeyAttribute "Status", "UpdateUtcTick", "CreateUtcTick", "General"
            $Schema | Add-DDBIndexSchema -IndexName "PK-SK3-Index" -RangeKeyName "SK3" -RangeKeyDataType "S" -ProjectionType "include" -NonKeyAttribute "Status", "UpdateUtcTick", "CreateUtcTick", "General"
            $Schema | Add-DDBIndexSchema -IndexName "PK-SK4-Index" -RangeKeyName "SK4" -RangeKeyDataType "S" -ProjectionType "include" -NonKeyAttribute "Status", "UpdateUtcTick", "CreateUtcTick", "General"
            $Schema | Add-DDBIndexSchema -IndexName "PK-SK5-Index" -RangeKeyName "SK5" -RangeKeyDataType "S" -ProjectionType "include" -NonKeyAttribute "Status", "UpdateUtcTick", "CreateUtcTick", "General"
            # $Schema | Add-DDBIndexSchema -Global -IndexName "GSI1" -HashKeyName "GSI1PK" -RangeKeyName "GSI1SK" -RangeKeyDataType "S" -ProjectionType "include" -NonKeyAttribute "Status", "UpdateUtcTick", "CreateUtcTick", "General" -ReadCapacity 10 -WriteCapacity 10

            New-DDBTable -TableName $TableName `
                -Region $Region `
                -Schema $Schema `
                -BillingMode "PAY_PER_REQUEST" `
                -ProfileName $ProfileName
        }
        catch {
            Write-Host "Error: Failed to create DynamoDB table"
            Write-Host "Hints:"
            Write-Host "  - Check if you have permission to create DynamoDB tables"
            Write-Host "  - Verify the table name is unique"
            Write-Host "  - Ensure the schema configuration is valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to create DynamoDB table: $($_.Exception.Message)" -ErrorAction Stop
        }

        # Wait for table to become active
        Write-LzAwsVerbose "Waiting for table to become active..."
        try {
            do {
                Start-Sleep -Seconds 5
                $TableStatus = (Get-DDBTable -TableName $TableName).TableStatus
            } while ($TableStatus -ne "ACTIVE")
        }
        catch {
            Write-Host "Error: Failed to wait for table to become active"
            Write-Host "Hints:"
            Write-Host "  - Check if the table was created successfully"
            Write-Host "  - Verify you have permission to read table status"
            Write-Host "  - Ensure the table name is correct"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to wait for table to become active: $($_.Exception.Message)" -ErrorAction Stop
        }

        # Enable TTL
        try {
            Update-DDBTimeToLive -TableName $TableName `
                -Region $Region `
                -TimeToLiveSpecification_AttributeName "TTL" `
                -TimeToLiveSpecification_Enable $true `
                -ProfileName $ProfileName
        }
        catch {
            Write-Host "Error: Failed to enable TTL on table"
            Write-Host "Hints:"
            Write-Host "  - Check if the table is in ACTIVE state"
            Write-Host "  - Verify you have permission to modify table settings"
            Write-Host "  - Ensure the TTL attribute name is correct"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to enable TTL on table: $($_.Exception.Message)" -ErrorAction Stop
        }

        Write-Host "Successfully created DynamoDB table: $TableName" -ForegroundColor Green
        return ""
    }
    catch {
        Write-Host "Error: An unexpected error occurred while creating DynamoDB table"
        Write-Host "Hints:"
        Write-Host "  - Check AWS service availability"
        Write-Host "  - Verify AWS credentials are valid"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "An unexpected error occurred while creating DynamoDB table: $($_.Exception.Message)" -ErrorAction Stop
    }
}