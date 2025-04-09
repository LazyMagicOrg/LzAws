# Error Handling Strategy

## Overview
This document outlines the error handling strategy for the LzAws module. The strategy is designed to provide clear, user-friendly error messages while maintaining proper error propagation through the call stack.

## Error Handling Patterns

### Private Functions (in `Private` folder)
Private functions should handle errors by creating a formatted error message and throwing it. This pattern ensures consistent error reporting and allows the calling public function to handle the error appropriately.

#### Pattern
```powershell
try {
    # Function logic here
} catch {
    $errorMessage = @"
Error: Brief description of what failed
Hints:
  - First hint about how to fix it
  - Second hint about how to fix it
  - Third hint about how to fix it
"@
    throw $errorMessage
}
```

#### Guidelines
1. Always create a formatted error message using a here-string (`@"..."@`)
2. Include a clear "Error:" line describing what failed
3. Provide helpful hints for troubleshooting
4. Use `throw` to stop execution and propagate the error
5. Keep error messages user-friendly and actionable
6. Include relevant context (e.g., file names, paths) in the error message

#### Example
```powershell
function Get-SystemConfig {
    try {
        $FilePath = Find-FileUp "systemconfig.yaml"
        if($null -eq $FilePath) {
            $errorMessage = @"
Error: Can't find systemconfig.yaml.
Hints:
  - Are you running this from the root of a solution?
  - Do you have a systemconfig.yaml file in a folder above the solution folder?
"@
            throw $errorMessage
        }
        # Rest of function...
    }
    catch {
        if ($_.Exception.Message -like "*Set-AWSCredential*") {
            $errorMessage = @"
Error: Failed to set AWS profile to '$ProfileName'
Hints:
  - Have you logged in? aws sso login --profile $ProfileName
  - Check if the profile exists in your AWS credentials file
  - Verify the profile has valid credentials
  - Try running 'aws configure list-profiles' to see available profiles
"@
            throw $errorMessage
        }
        throw "Error: Failed to load system configuration: $($_.Exception.Message)"
    }
}
```

### Public Functions (in `Public` folder)
Public functions are entry points that users directly call. These functions should handle errors by displaying error messages and stopping execution.

#### Pattern
```powershell
try {
    # Operation code
}
catch {
    Write-Host $_.Exception.Message
    exit 1
}
```

#### Guidelines
1. Display error messages from private functions using `Write-Host`
2. Use `exit 1` to stop execution
3. Do not use `throw` directly
4. Keep error messages user-friendly and actionable
5. Include helpful hints for troubleshooting
6. Show relevant error details without exposing internal information

#### Example
```powershell
function Deploy-TestError {
    try {
        $SystemConfig = Get-SystemConfig
        # Rest of function...
    }
    catch {
        Write-Host $_.Exception.Message
        return false
    }
} 