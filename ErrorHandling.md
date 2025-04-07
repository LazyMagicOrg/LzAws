# Error Handling Strategy

## Overview
This document outlines the error handling strategy for the LzAws module. The strategy is designed to provide clear, user-friendly error messages while maintaining proper error propagation through the call stack.

## Error Handling Patterns

### 1. Public Functions (in `Public` folder)
Public functions are entry points that users directly call. These functions use `exit 1` for error handling to provide clean, user-friendly error messages.

Example pattern:
```powershell
try {
    # Operation code
}
catch {
    Write-Host "Error: <descriptive message>"
    Write-Host "Hints:"
    Write-Host "  - <helpful hint 1>"
    Write-Host "  - <helpful hint 2>"
    Write-Host "Error Details: $($_.Exception.Message)"
    exit 1
}
```

Key points:
- Use `exit 1` to stop execution and return an error code
- Provide clear, user-friendly error messages
- Include helpful hints for troubleshooting
- Show relevant error details without exposing internal information

### 2. Private Functions (in `Private` folder)
Private functions are internal helpers called by public functions. These functions use `Write-Error -ErrorAction Stop` to properly propagate errors up to the calling function.

Example pattern:
```powershell
try {
    # Operation code
}
catch {
    Write-Host "Error: <descriptive message>"
    Write-Host "Hints:"
    Write-Host "  - <helpful hint 1>"
    Write-Host "  - <helpful hint 2>"
    Write-Host "Error Details: $($_.Exception.Message)"
    Write-Error "<descriptive message>: $($_.Exception.Message)" -ErrorAction Stop
}
```

Key points:
- Use `Write-Error -ErrorAction Stop` to propagate errors
- Provide descriptive error messages
- Include helpful hints for debugging
- Allow the calling function to handle the error appropriately

### 3. Module Functions (in `LzAws.psm1`)
Module-level functions use `Write-Error` for internal error handling.

Example pattern:
```powershell
try {
    # Operation code
}
catch {
    Write-Error "Failed to <operation>: $_"
    return $false
}
```

Key points:
- Use `Write-Error` for internal module errors
- Keep error messages concise and specific
- Return appropriate values to indicate failure

## Why Not Use `throw`?
We avoid using `throw` because:
1. It exposes too much internal information in the error stack trace
2. It can be disruptive to the user experience
3. It makes error handling more complex for calling functions
4. It doesn't provide the clean, controlled error handling we need for deployment scripts

## Best Practices
1. Always provide clear, user-friendly error messages
2. Include helpful hints for troubleshooting
3. Show relevant error details without exposing internal information
4. Use appropriate error handling based on function scope (public vs private)
5. Maintain consistent error handling patterns across similar functions
6. Document error conditions and handling in function comments 