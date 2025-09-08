# Remote Temporary Admin

This directory contains PowerShell scripts for managing temporary administrator access on remote Windows servers. It provides a simplified, streamlined approach specifically focused on the Administrators group using PowerShell remoting.

## Overview

These scripts provide a dedicated solution for granting and revoking administrator-level access on remote servers. Unlike the more flexible `local-admin-remote-server` scripts, these are specifically designed for administrator access scenarios with simplified user identity handling.

## Files

- **`RemoteAdmin-checkout.ps1`** - Grants temporary administrator access to a user on a remote server
- **`RemoteAdmin-checkin.ps1`** - Revokes administrator access from a user on a remote server

## Key Features

- **Administrator-Specific**: Hardcoded to work with the "Administrators" local group
- **Email-Based Identity**: Constructs user identity from email address
- **Domain Integration**: Combines username with domain for full user principal name
- **PowerShell Remoting**: Secure remote execution using `Invoke-Command`
- **Error Handling**: Comprehensive error reporting with descriptive messages

## Architecture

```
[Management System] --PowerShell Remoting--> [Target Server]
         ↓                                            ↓
    Email + Domain                          Add/Remove from
         ↓                                   Administrators
   User@Domain.com                               Group
```

## Environment Variables

The scripts use the following environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `$env:email` | User's email address | `john.doe@company.com` |
| `$env:domain` | Target domain | `corp.domain.com` |
| `$env:target` | Target server FQDN/IP | `server01.corp.domain.com` |

## User Identity Construction

The scripts construct the user identity as follows:

```powershell
# Extract username from email (before '@' and before first '-')
$UserName = $env:email.Split('@')[0].Split('-')[0]

# Combine with domain
$FullUser = "$UserName@$Domain"

# Example: john.doe@company.com + corp.domain.com = john.doe@corp.domain.com
```

## Usage

### Granting Administrator Access (Checkout)

```powershell
# Set environment variables
$env:email = "john.doe@company.com"
$env:domain = "corp.domain.com"
$env:target = "server01.corp.domain.com"

# Execute checkout script
.\RemoteAdmin-checkout.ps1
```

**Expected Output**:
```
User john.doe@corp.domain.com added to Administrators group
```

### Revoking Administrator Access (Checkin)

```powershell
# Set environment variables
$env:email = "john.doe@company.com"  
$env:domain = "corp.domain.com"
$env:target = "server01.corp.domain.com"

# Execute checkin script
.\RemoteAdmin-checkin.ps1
```

**Expected Output**:
```
User john.doe@corp.domain.com removed from Administrators group
```

## Prerequisites

### PowerShell Remoting
- **WinRM Service**: Enabled and running on target servers
- **PowerShell Remoting**: Configured and accessible
- **Network Connectivity**: Management system can reach target servers
- **Firewall Rules**: WinRM ports (5985/5986) open

### Authentication & Permissions
- **Domain Authentication**: Proper Kerberos/NTLM configuration
- **Administrative Rights**: Permissions to modify Administrators group
- **Execution Policy**: PowerShell execution enabled
- **Remote Access**: Rights to execute remote commands

### Domain Configuration
- **User Accounts**: Target users must exist in the specified domain
- **Group Policy**: Appropriate policies for remote administration
- **DNS Resolution**: Proper name resolution for target servers

## Error Handling

### Common Error Scenarios

1. **User Not Found**
   ```
   Failed to add user john.doe@corp.domain.com: The specified account does not exist
   ```

2. **Access Denied**  
   ```
   Failed to add user john.doe@corp.domain.com: Access is denied
   ```

3. **Server Unreachable**
   ```
   Failed to connect to server01.corp.domain.com: WinRM cannot complete the operation
   ```

4. **User Already Administrator** (Checkout)
   ```
   Failed to add user john.doe@corp.domain.com: The specified account name is already a member of the group
   ```

5. **User Not Administrator** (Checkin)
   ```
   Failed to add user john.doe@corp.domain.com: The specified account name is not a member of the group
   ```

### Error Note in Checkin Script
There's a comment discrepancy in the checkin script:
```powershell
# Line 14: Write-Error "Failed to add user ${RemoteUser}: $($_.Exception.Message)"
# Should be: Write-Error "Failed to remove user ${RemoteUser}: $($_.Exception.Message)"
```

## Security Considerations

### Access Control
- **Time-Limited Access**: Implement automatic timeout/expiration
- **Approval Workflow**: Require approval before granting admin access  
- **Session Monitoring**: Monitor administrator activity during access period
- **Audit Logging**: Log all administrator access grants and revocations

### Authentication Security
- **Strong Authentication**: Use multi-factor authentication where possible
- **Least Privilege**: Grant access only when necessary
- **Regular Review**: Periodically review administrator access grants
- **Automated Cleanup**: Ensure reliable revocation processes

### Network Security
- **Encrypted Communication**: PowerShell remoting uses encrypted channels
- **VPN/Private Networks**: Execute from secure network segments
- **Firewall Restrictions**: Limit WinRM access to authorized systems
- **Certificate-Based Authentication**: Consider certificate authentication

## Integration Patterns

### PAM System Integration
```powershell
# Typical workflow:
1. User requests admin access through PAM portal
2. PAM system validates request and approves
3. PAM sets environment variables and executes checkout
4. User performs administrative tasks
5. PAM automatically executes checkin after time limit
```

### Scheduled Cleanup
```powershell
# Example scheduled task for automatic cleanup
$users = @("user1@domain.com", "user2@domain.com")
foreach ($user in $users) {
    $env:email = $user.Split('@')[0] + "@company.com"
    $env:domain = "corp.domain.com" 
    $env:target = "server01.corp.domain.com"
    .\RemoteAdmin-checkin.ps1
}
```

## Monitoring and Auditing

### Windows Event Logs
Monitor these events on target servers:
- **Event ID 4732**: Member added to security-enabled local group
- **Event ID 4733**: Member removed from security-enabled local group
- **Event ID 4624**: Successful logon (admin user)
- **Event ID 4634**: Logoff (admin user)

### PowerShell Logging
Enable detailed PowerShell logging:
```powershell
# Group Policy settings:
# Computer Configuration > Administrative Templates > Windows Components > Windows PowerShell
# - Turn on Module Logging
# - Turn on PowerShell Script Block Logging  
# - Turn on PowerShell Transcription
```

### Custom Audit Trail
Consider adding custom logging:
```powershell
# Example audit logging addition
$auditLog = "C:\Logs\AdminAccess.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$entry = "$timestamp - CHECKOUT - User: $FullUser, Server: $TargetComputer"
Add-Content -Path $auditLog -Value $entry
```

## Troubleshooting

### Connection Testing
```powershell
# Test basic connectivity
Test-NetConnection -ComputerName $env:target -Port 5985

# Test WinRM
Test-WSMan -ComputerName $env:target

# Test PowerShell remoting
Invoke-Command -ComputerName $env:target -ScriptBlock { Get-ComputerInfo }
```

### User Verification
```powershell
# Verify user exists in domain
Get-ADUser -Filter "UserPrincipalName -eq '$FullUser'" -Server $env:domain

# Check current Administrators group membership
Invoke-Command -ComputerName $env:target -ScriptBlock {
    Get-LocalGroupMember -Group "Administrators"
}
```

### Permission Verification
```powershell
# Check if current user can manage local groups
Invoke-Command -ComputerName $env:target -ScriptBlock {
    try {
        Get-LocalGroup -Name "Administrators" -ErrorAction Stop
        Write-Output "Success: Can access local groups"
    } catch {
        Write-Output "Error: Cannot access local groups - $($_.Exception.Message)"
    }
}
```

## Best Practices

1. **Input Validation**: Validate all environment variables before processing
2. **Timeout Implementation**: Set reasonable timeouts for remote operations  
3. **Retry Logic**: Implement retry for transient network failures
4. **Logging**: Log all operations with timestamps and user details
5. **Regular Cleanup**: Schedule regular cleanup jobs to remove stale access
6. **Testing**: Test thoroughly in development environments before production use
7. **Documentation**: Document all administrator access grants and business justification
