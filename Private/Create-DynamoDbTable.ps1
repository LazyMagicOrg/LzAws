function Create-DynamoDbTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )
    $Region = $script:Region
    $ProfileName = $script:ProfileName

    # Check if table exists
    try {
        $ExistingTable = Get-DDBTable -TableName $TableName -Region $Region -ErrorAction SilentlyContinue -ProfileName $ProfileName
        if ($ExistingTable) {
            Write-LzAwsVerbose "Table '$TableName' exists."
            return
        }
    }
    catch {
        # If the error is "Table not found", that's expected and we can continue
        if ($_.Exception.Message -like "*Table: $TableName not found*") {
            Write-LzAwsVerbose "Table '$TableName' does not exist, proceeding with creation."
        }
        else {
            $errorMessage = @"
Error: Failed to check if table exists
Function: Create-DynamoDbTable
Hints:
  - Check if you have permission to read DynamoDB tables
  - Verify AWS credentials are valid
  - Ensure the region is correct
  - Review AWS IAM permissions

Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }
    }
    Write-LzAwsVerbose "Creating DynamoDB table $TableName"

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

        $null = New-DDBTable -TableName $TableName `
            -Region $Region `
            -Schema $Schema `
            -BillingMode "PAY_PER_REQUEST" `
            -ProfileName $ProfileName
    }
    catch {
        $errorMessage = @"
Error: Failed to create DynamoDB table
Function: Create-DynamoDbTable
Hints:
  - Check if you have permission to create DynamoDB tables
  - Verify the table name is unique
  - Ensure the schema configuration is valid
  - Review AWS IAM permissions

Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
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
        $errorMessage = @"
Error: Failed to wait for table to become active
Function: Create-DynamoDbTable
Hints:
  - Check if the table was created successfully
  - Verify you have permission to read table status
  - Ensure the table name is correct
  - Review AWS CloudWatch logs

Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
    }
    Write-LzAwsVerbose "Table '$TableName' is now active"  
    Write-LzAwsVerbose "Enabling TTL"
    # Enable TTL
    try {
        $null = Update-DDBTimeToLive -TableName $TableName `
            -Region $Region `
            -TimeToLiveSpecification_AttributeName "TTL" `
            -TimeToLiveSpecification_Enable $true `
            -ProfileName $ProfileName
    }
    catch {
        $errorMessage = @"
Error: Failed to enable TTL on table
Function: Create-DynamoDbTable
Hints:
  - Check if the table is in ACTIVE state
  - Verify you have permission to modify table settings
  - Ensure the TTL attribute name is correct
  - Review AWS IAM permissions

Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
    }

    Write-Host "Successfully created DynamoDB table: $TableName" -ForegroundColor Green
    return ""
}