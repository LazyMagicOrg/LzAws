# LzAws PowerShell Module

## Overview

LzAws is a PowerShell module designed for deploying and managing multi-tenant SaaS applications on AWS. It provides a comprehensive set of cmdlets for managing AWS infrastructure, including system resources, tenant configurations, authentication systems, web applications, and static assets.

## Features

- **Multi-tenant Architecture Support**: Deploy and manage isolated resources for multiple tenants
- **Infrastructure as Code**: Uses AWS SAM/CloudFormation templates for consistent deployments
- **Comprehensive Resource Management**: Covers system infrastructure, services, authentication, policies, and assets
- **AWS SSO Integration**: Supports AWS SSO profiles and standard AWS credentials
- **Error Handling**: Clear, actionable error messages with troubleshooting hints
- **Modular Design**: Organized public cmdlets with internal helper functions

## Prerequisites

- PowerShell 5.1 or higher
- AWS SAM CLI installed and configured
- Valid AWS credentials (IAM user or SSO profile)
- AWS PowerShell modules (automatically managed by LzAws)

## Installation

### Option 1: Install for Current User
```powershell
.\Install-LzAws.ps1 -Scope CurrentUser
```

### Option 2: Install for All Users (requires admin)
```powershell
.\Install-LzAws.ps1 -Scope AllUsers
```

### Development Usage
For development or testing without installation:
```powershell
.\Import-LzAws.ps1
```

## Configuration

LzAws requires a `systemconfig.yaml` file in your project hierarchy. The module will search up the directory tree to find this file.

### Sample systemconfig.yaml Structure
```yaml
SystemKey: myapp
SystemSuffix: prod
AwsProfile: myapp-prod
Region: us-east-1

Tenants:
  - TenantKey: tenant1
    Domain: tenant1.example.com
    CertificateArn: arn:aws:acm:us-east-1:123456789012:certificate/...
  - TenantKey: tenant2
    Domain: tenant2.example.com
    CertificateArn: arn:aws:acm:us-east-1:123456789012:certificate/...

Services:
  - ServiceKey: api
    Template: Templates/sam.service.api.yaml
  - ServiceKey: auth
    Template: Templates/sam.service.auth.yaml
```

## Core Cmdlets

### System Deployment

#### Deploy-SystemAws
Deploys the core AWS infrastructure for your system.
```powershell
Deploy-SystemAws
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder
- Deploys system-wide resources (S3 buckets, DynamoDB tables)
- Creates the system stack with key-value store
- Must be run before tenant deployments

### Tenant Management

#### Deploy-TenantAws
Deploys infrastructure for a specific tenant.
```powershell
Deploy-TenantAws -TenantKey "tenant1"
```

#### Deploy-TenantsAws
Deploys infrastructure for all tenants defined in configuration.
```powershell
Deploy-TenantsAws
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder
- 
#### Get-TenantConfigAws
Generates tenant configuration JSON file.
```powershell
Get-TenantConfigAws -TenantKey "tenant1"
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder
- 
### Service Deployment

#### Deploy-ServiceAws
Deploys Lambda functions and API services.
```powershell
Deploy-ServiceAws -ServiceKey "api"
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder

### Authentication

#### Deploy-AuthsAws
Deploys Cognito user pools and authentication configurations.
```powershell
Deploy-AuthsAws
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder
  
#### Set-Admin
Sets admin status for a user in Cognito.
```powershell
Set-Admin -TenantKey "tenant1" -Email "admin@example.com" -IsAdmin $true
```

### Web Application

#### Deploy-WebappAws
Deploys frontend web applications.
```powershell
Deploy-WebappAws
```
This cmdlet:
- Must be run from the App's solution folder
  
### Asset Management

#### Deploy-AssetsAws
Deploys static assets to S3 buckets.
```powershell
Deploy-AssetsAws
```
This cmdlet:
- Must be run from the Tenancies solution folder.
 
#### Get-AssetsAws
Lists assets in tenant S3 buckets.
```powershell
Get-AssetsAws -TenantKey "tenant1"
```
This cmdlet:
- Must be run from the Tenancies solution folder.
  
### Policies

#### Deploy-PoliciesAws
Deploys CloudFront and caching policies.
```powershell
Deploy-PoliciesAws
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder

#### Deploy-PermsAws
Deploys permission policies to AWS.
```powershell
Deploy-PermsAws
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder
  
### Utilities

#### Get-AwsCommands
Lists all available LzAws commands.
```powershell
Get-AwsCommands
```

#### Get-LzAwsHelp
Provides detailed help for any LzAws command.
```powershell
Get-LzAwsHelp -CommandName "Deploy-TenantAws"
```

#### Get-VersionAws
Gets the current version of the LzAws module.
```powershell
Get-VersionAws
```

#### Get-CDNLogAws
Retrieves CloudFront CDN logs.
```powershell
Get-CDNLogAws -TenantKey "tenant1" -StartDate "2024-01-01" -EndDate "2024-01-31"
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder
  
#### Get-KvsEntries
Gets entries from the key-value store.
```powershell
Get-KvsEntries
```
This cmdlet:
- Must be run from the Service/AwsTemplates folder
  
### Testing

#### Deploy-TestError
Tests error handling functionality.
```powershell
Deploy-TestError
```

## Deployment Workflow

The typical deployment sequence for a new system:

1. **System Infrastructure**
   ```powershell
   Deploy-SystemAws
   ```
2. **Policies**
   ```powershell
   Deploy-PoliciesAws
   Deploy-PermsAws
   ```
3. **Authentication**
   ```powershell
   Deploy-AuthsAws
   ```
4. **Services and APIs**
   ```powershell
   Deploy-ServiceAws
   ```

5. **Web Application**
   ```powershell
   Deploy-WebappAws
   ```

6. **Static Assets**
   ```powershell
   Deploy-AssetsAws
   ```

7. **Tenant Resources**
   ```powershell
   Deploy-TenantsAws
   # or for a specific tenant
   Deploy-TenantAws -TenantKey "tenant1"
   ```

## AWS Profile Configuration

### Using AWS SSO
```powershell
# Login to AWS SSO
aws sso login --profile myapp-dev

# The module will use the profile specified in systemconfig.yaml
Deploy-SystemAws
```

### Using IAM Credentials
Ensure your AWS credentials are configured:
```powershell
aws configure --profile myapp-dev
```

## Verbose Output

Enable verbose logging to see detailed operation information:
```powershell
$LzAwsVerbosePreference = "Continue"
Deploy-SystemAws
```

## Error Handling

LzAws provides detailed error messages with troubleshooting hints:
```
Error: Can't find systemconfig.yaml
Function: Get-SystemConfig
Hints:
  - Are you running this from the root of a solution?
  - Do you have a systemconfig.yaml file in a folder above?
  - Check that the file name is exactly 'systemconfig.yaml'
```

## Common Issues and Solutions

### Issue: "Failed to set AWS profile"
**Solution**: 
- Run `aws sso login --profile <profile-name>`
- Verify the profile exists: `aws configure list-profiles`
- Check AWS credentials are valid

### Issue: "No changes to deploy"
**Solution**: This is normal when the infrastructure is already up-to-date. No action needed.

### Issue: "Template file not found"
**Solution**: 
- Ensure you're running from the AwsTemplates folder in your service solution
- Verify template files exist in the Templates directory
- Check template paths in systemconfig.yaml

### Issue: "Access Denied" errors
**Solution**:
- Verify your AWS profile has necessary permissions
- Check IAM policies attached to your user/role
- Ensure you're using the correct AWS region

## Best Practices

1. **Always deploy system resources first** - Other resources depend on system infrastructure
2. **Use consistent naming** - Follow the SystemKey and TenantKey naming conventions
3. **Test in non-production first** - Use separate SystemSuffix for different environments
4. **Monitor deployments** - Check AWS CloudFormation console for detailed status
5. **Keep configurations in version control** - Track changes to systemconfig.yaml
6. **Use verbose mode for troubleshooting** - Helps identify where issues occur

## Module Structure

- **Public/**: User-facing cmdlets (Deploy-*, Get-*, Set-*)
- **Private/**: Internal helper functions
- **Templates/**: SAM/CloudFormation templates (not included in module)
- **en-US/**: Help documentation and localization

## Support and Contributing

- Report issues: [GitHub Issues](https://github.com/LazyMagicOrg/LzAws/issues)
- Documentation: Check CLAUDE.md for detailed development guidelines
- Error handling: See ErrorHandling.md for error handling patterns

## License

This module is licensed under the MIT License. See LICENSE file for details.