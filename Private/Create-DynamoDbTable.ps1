function Create-DynamoDbTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )
    $Region = $script:Region
    $ProfileName = $script:ProfileName

    # Validate required script variables
    if ([string]::IsNullOrWhiteSpace($Region)) {
        $errorMessage = @"
Error: Region is null or empty
Function: Create-DynamoDbTable
Hints:
  - Ensure Get-SystemConfig has been called first
  - Verify systemconfig.yaml contains a Region property
  - Check that `$script:Region is set properly
Current Values:
  Region: '$Region'
  ProfileName: '$ProfileName'
"@
        throw $errorMessage
    }

    if ([string]::IsNullOrWhiteSpace($ProfileName)) {
        $errorMessage = @"
Error: ProfileName is null or empty
Function: Create-DynamoDbTable
Hints:
  - Ensure Get-SystemConfig has been called first
  - Verify systemconfig.yaml contains a Profile property
  - Check that `$script:ProfileName is set properly
Current Values:
  Region: '$Region'
  ProfileName: '$ProfileName'
"@
        throw $errorMessage
    }

    Write-LzAwsVerbose "Create-DynamoDbTable called with: TableName='$TableName', Region='$Region', ProfileName='$ProfileName'"

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
        Write-LzAwsVerbose "Creating new table schema"
        $Schema = New-DDBTableSchema
        if ($null -eq $Schema) {
            throw "New-DDBTableSchema returned null"
        }

        Write-LzAwsVerbose "Adding primary key schema"
        $Schema = $Schema | Add-DDBKeySchema -KeyName "PK" -KeyDataType "S" -KeyType "HASH"
        if ($null -eq $Schema) {
            throw "Schema is null after adding HASH key"
        }

        $Schema = $Schema | Add-DDBKeySchema -KeyName "SK" -KeyDataType "S" -KeyType "RANGE"
        if ($null -eq $Schema) {
            throw "Schema is null after adding RANGE key"
        }

        # Add Local Secondary Indexes (LSI) - these share the table's partition key (PK)
        Write-LzAwsVerbose "Adding Local Secondary Indexes"

        Write-LzAwsVerbose "Adding PK-SK1-Index"
        $Schema = $Schema | Add-DDBIndexSchema -IndexName "PK-SK1-Index" -RangeKeyName "SK1" -RangeKeyDataType "S" -ProjectionType "ALL"

        Write-LzAwsVerbose "Adding PK-SK2-Index"
        $Schema = $Schema | Add-DDBIndexSchema -IndexName "PK-SK2-Index" -RangeKeyName "SK2" -RangeKeyDataType "S" -ProjectionType "ALL"

        Write-LzAwsVerbose "Adding PK-SK3-Index"
        $Schema = $Schema | Add-DDBIndexSchema -IndexName "PK-SK3-Index" -RangeKeyName "SK3" -RangeKeyDataType "S" -ProjectionType "ALL"

        Write-LzAwsVerbose "Adding PK-SK4-Index"
        $Schema = $Schema | Add-DDBIndexSchema -IndexName "PK-SK4-Index" -RangeKeyName "SK4" -RangeKeyDataType "S" -ProjectionType "ALL"

        Write-LzAwsVerbose "Adding PK-SK5-Index"
        $Schema = $Schema | Add-DDBIndexSchema -IndexName "PK-SK5-Index" -RangeKeyName "SK5" -RangeKeyDataType "S" -ProjectionType "ALL"

        # Example GSI (commented out)
        # $Schema = $Schema | Add-DDBIndexSchema -Global -IndexName "GSI1" -HashKeyName "GSI1PK" -HashKeyDataType "S" -RangeKeyName "GSI1SK" -RangeKeyDataType "S" -ProjectionType "INCLUDE" -NonKeyAttribute $NonKeyAttrs -ReadCapacity 10 -WriteCapacity 10

        Write-LzAwsVerbose "Creating table with schema"
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
Exception Type: $($_.Exception.GetType().FullName)
Stack Trace: $($_.ScriptStackTrace)
"@
        throw $errorMessage
    }

    # Wait for table to become active
    Write-LzAwsVerbose "Waiting for table to become active..."
    try {
        do {
            Start-Sleep -Seconds 5
            $TableStatus = (Get-DDBTable -TableName $TableName -Region $Region -ProfileName $ProfileName).TableStatus
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