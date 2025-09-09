# Local Admin Remote Server

This directory contains PowerShell scripts for managing local group membership on remote Windows servers using PowerShell remoting. It provides a flexible checkout/checkin system for granting and revoking group-based access.

## Overview

These scripts enable just-in-time (JIT) access management by adding and removing users from local groups on remote servers. The solution supports any local group (Administrators, Remote Desktop Users, etc.) and uses secure PowerShell remoting for execution.

## Files

- **`checkout.ps1`** - Adds a user to a specified local group on a remote server
- **`checkin.ps1`** - Removes a user from a specified local group on a remote server

## Architecture

```
[Management Server] --PowerShell Remoting--> [Target Server]
     ↓ checkout.ps1                              ↓ Add-LocalGroupMember
     ↓ checkin.ps1                               ↓ Remove-LocalGroupMember
```

## Prerequisites

### PowerShell Remoting

- **WinRM Service**: Must be running on target servers
- **PowerShell Remoting**: Enabled on target servers
- **Network Connectivity**: Management server must reach target servers
- **Execution Policy**: Allow script execution

### Authentication

- **Credentials**: Appropriate credentials for remote server access
- **Permissions**: Rights to manage local groups on target servers
- **Kerberos/NTLM**: Properly configured authentication

## Environment Variables

Both scripts use the following environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `$env:user` | User UPN (User Principal Name) | `jdoe@domain.com` |
| `$env:target` | Target server FQDN or IP | `server01.domain.com` |
| `$env:group` | Target local group name | `Administrators` |

## Usage

### Granting Access (Checkout)

```powershell
# Set environment variables
$env:user = "jdoe@domain.com"
$env:target = "server01.domain.com"  
$env:group = "Administrators"

# Execute checkout script
.\checkout.ps1
```

**Expected Output**:
```
User jdoe@domain.com added to group Administrators
```

### Revoking Access (Checkin)

```powershell
# Set environment variables  
$env:user = "jdoe@domain.com"
$env:target = "server01.domain.com"
$env:group = "Administrators"

# Execute checkin script
.\checkin.ps1
```

**Expected Output**:
```
User jdoe@domain.com removed from group Administrators
```

## Supported Local Groups

The scripts work with any Windows local group, including:

- **`Administrators`** - Full administrative access
- **`Remote Desktop Users`** - RDP access permissions
- **`Power Users`** - Limited administrative privileges (legacy)
- **`Users`** - Standard user access
- **`Backup Operators`** - Backup and restore privileges
- **`Event Log Readers`** - Event log reading permissions
- **Custom Groups** - Any locally created groups

## Error Handling

Both scripts implement comprehensive error handling:

### Common Error Scenarios

- **User Not Found**: Domain user doesn't exist or isn't accessible
- **Group Not Found**: Specified local group doesn't exist on target server
- **Access Denied**: Insufficient privileges to modify group membership
- **Network Issues**: Cannot reach target server via PowerShell remoting
- **User Already Exists**: (Checkout) User is already a member of the group
- **User Not Member**: (Checkin) User is not a member of the group

### Error Output Format

```powershell
Write-Error "Failed to add user jdoe@domain.com to group Administrators: Access denied"
```

## Security Considerations

### Execution Security

- **Least Privilege**: Execute with minimum required permissions
- **Secure Channels**: PowerShell remoting uses encrypted communication
- **Authentication**: Leverages Windows integrated authentication
- **Audit Logging**: All operations should be logged for compliance

### Access Control

- **Time-Limited Access**: Implement time-based access controls
- **Approval Workflows**: Integrate with approval systems before execution
- **Session Monitoring**: Monitor user activity during elevated access
- **Automatic Cleanup**: Ensure checkin processes run reliably

## Monitoring and Auditing

### PowerShell Logging

Enable PowerShell script block logging to capture all script execution:

```powershell
# Group Policy: Administrative Templates > Windows Components > Windows PowerShell
# Enable "Turn on PowerShell Script Block Logging"
```

### Event Log Monitoring

Monitor Windows Event Logs on target servers:

- **Security Log**: User group membership changes (Event ID 4732, 4733)
- **System Log**: Service and authentication events
- **PowerShell Operational Log**: Script execution details

### Custom Logging

Consider adding custom logging to scripts:

```powershell
# Example logging addition
$logEntry = "$(Get-Date): User $UserUPN added to group $TargetGroup on $TargetComputer"
Add-Content -Path "C:\Logs\GroupManagement.log" -Value $logEntry
```

## Troubleshooting

### Connection Issues

```powershell
# Test PowerShell remoting
Test-WSMan -ComputerName $env:target

# Test remote connectivity
Invoke-Command -ComputerName $env:target -ScriptBlock { Get-ComputerInfo }
```

### Permission Issues

```powershell
# Verify current user permissions
whoami /groups
whoami /priv

# Test local group access on target
Invoke-Command -ComputerName $env:target -ScriptBlock { Get-LocalGroup }
```

### Group Membership Verification

```powershell
# Check current group membership
Invoke-Command -ComputerName $env:target -ScriptBlock { 
    Get-LocalGroupMember -Group $using:env:group 
}
```

## Best Practices

1. **Input Validation**: Validate environment variables before execution
2. **Error Logging**: Log all operations and errors for audit trails
3. **Timeouts**: Implement reasonable timeouts for remote operations
4. **Retry Logic**: Add retry mechanisms for transient network issues
5. **Clean Exit**: Ensure scripts exit cleanly in all scenarios
6. **Testing**: Thoroughly test in non-production environments first
