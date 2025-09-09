# Temporary Local User

This directory contains PowerShell scripts for creating and managing temporary local user accounts with automatic password generation and comprehensive cleanup capabilities. It provides a complete lifecycle management solution for temporary access scenarios to be sued by the Britive Access Broker.

## Overview

These scripts enable the creation of temporary local user accounts for short-term access needs, such as contractor work, emergency access, or temporary project requirements. The solution handles the complete user lifecycle from creation to cleanup, including optional RDP session termination.

## Files

- **`checkout.ps1`** - Creates temporary local user accounts with generated passwords and group membership
- **`checkin.ps1`** - Removes temporary local user accounts and optionally terminates active RDP sessions

## Key Features

### Checkout Process (`checkout.ps1`)

- **Automatic Password Generation**: Creates secure 12-character passwords with mixed character sets
- **User Account Management**: Creates new users or resets passwords for existing users
- **Group Assignment**: Automatically adds users to specified local groups
- **Credential Output**: Returns username and password in structured format
- **Username Sanitization**: Removes non-alphanumeric characters from usernames

### Checkin Process (`checkin.ps1`)

- **Complete User Removal**: Permanently deletes local user accounts
- **RDP Session Termination**: Optional killing of active RDP sessions
- **Session Management**: Uses `qwinsta` and `Invoke-RDUserLogoff` for session control
- **Error Handling**: Graceful handling of cleanup scenarios

## Architecture

```
Email Input → Username Extraction → Sanitization → Local User Creation
     ↓                                                      ↓
Password Generation ← Group Membership ← Account Setup ←──────┘
     ↓
Credential Output

[Later - Checkin]
Optional RDP Kill → Local User Removal → Complete Cleanup
```

## Environment Variables

### Checkout Script

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `$env:email` | User's email address | `john.doe@company.com` | Yes |
| `$env:group` | Target local group | `Remote Desktop Users` | Yes |

### Checkin Script

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `$env:email` | User's email address | `john.doe@company.com` | Yes |
| `$env:killrdp` | Kill RDP sessions flag | `"1"` or `"0"` | No (default: `"0"`) |

## Username Processing

The scripts process usernames as follows:

```powershell
# Extract username from email (before '@')
$username = $email.Split('@')[0]

# Sanitize username (remove non-alphanumeric characters)  
$user = $username -replace '[^a-zA-Z0-9]', ''

# Example: john.doe@company.com → johndoe
```

## Password Generation

The checkout script generates secure passwords with the following specifications:

```powershell
# Password characteristics
- Length: 12 characters
- Character set: a-z, A-Z, 0-9, and special characters
- Special characters: !@#$%^&*()_-+=[]{}|;:,.<>?/~
- Random generation for each execution
```

## Usage

### Creating Temporary User (Checkout)

```powershell
# Set environment variables
$env:email = "john.doe@company.com"
$env:group = "Remote Desktop Users"

# Execute checkout script
.\checkout.ps1
```

**Expected Output**:
```
username:s:johndoe
password:s:A3k9#mP2$xB1
```

### Removing Temporary User (Checkin)

```powershell
# Set environment variables
$env:email = "john.doe@company.com"
$env:killrdp = "1"  # Optional: terminate RDP sessions

# Execute checkin script  
.\checkin.ps1
```

**Expected Output** (if successful):

```
Removing local user: johndoe
```

## Supported Local Groups

The checkout script can add users to any Windows local group:

- **`Remote Desktop Users`** - Standard RDP access
- **`Administrators`** - Full administrative privileges (use with caution)
- **`Users`** - Basic user access
- **`Power Users`** - Limited administrative privileges (legacy)
- **`Backup Operators`** - Backup and restore rights
- **`Event Log Readers`** - Event log reading permissions
- **Custom Groups** - Any locally created groups

## RDP Session Management

The checkin script includes optional RDP session termination:

### Session Detection

```powershell
# Uses qwinsta command to find user sessions
$qwinstaOutput = qwinsta $Username
$sessionIds = # Parse session IDs from output
```

### Session Termination

```powershell
# Uses Invoke-RDUserLogoff for forceful session termination
Invoke-RDUserLogoff -HostServer localhost -UnifiedSessionID $session -Force
```

### Control Flag

- **`$env:killrdp = "1"`**: Terminate RDP sessions before user removal
- **`$env:killrdp = "0"`** or **unset**: Skip RDP session termination

## Error Handling

### Checkout Script Errors

- **Invalid Email**: Script validates `$env:email` and `$env:group` are not null
- **User Creation Failure**: Handles errors in `New-LocalUser` operations
- **Group Assignment Failure**: Manages errors in `Add-LocalGroupMember`
- **Password Generation**: Ensures secure password creation

### Checkin Script Errors

- **User Not Found**: Gracefully handles cases where user doesn't exist
- **RDP Session Errors**: Continues with user removal even if session termination fails
- **Permission Denied**: Reports but continues with cleanup process

### Error Output Examples

```powershell
# User creation error
Write-Error "Creating new local user: johndoe"

# Group assignment error  
Write-Error "Setting new password for existing user: johndoe"

# User removal error
Write-Error "Error removing local user: Access denied"
```

## Security Considerations

### Password Security

- **Strong Generation**: 12-character passwords with multiple character types
- **Random Generation**: New password for each execution
- **Secure Storage**: Passwords displayed only during checkout
- **No Persistence**: Passwords not stored in files or logs

### Account Security

- **Limited Lifespan**: Accounts intended for temporary use only
- **Group-Based Access**: Access limited by group membership
- **Regular Cleanup**: Implement automated cleanup processes
- **Session Control**: Optional RDP session termination

### Audit and Compliance

- **User Creation Logging**: Windows logs local user creation events
- **Group Membership Tracking**: Monitor group assignment changes
- **Session Monitoring**: Track RDP session activities
- **Regular Review**: Audit temporary account usage patterns

## Monitoring and Auditing

### Windows Event Logs

Monitor these events:

- **Event ID 4720**: User account created
- **Event ID 4726**: User account deleted  
- **Event ID 4732**: Member added to security-enabled local group
- **Event ID 4733**: Member removed from security-enabled local group
- **Event ID 4624**: Successful account logon
- **Event ID 4634**: Account logoff

### PowerShell Logging

Enable comprehensive PowerShell logging:

```powershell
# Group Policy: Computer Configuration > Administrative Templates > 
# Windows Components > Windows PowerShell
# Enable:
# - Turn on Module Logging
# - Turn on PowerShell Script Block Logging
# - Turn on PowerShell Transcription
```

### Custom Logging

Add custom audit logging:

```powershell
# Example logging additions
$logFile = "C:\Logs\TempUserManagement.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$entry = "$timestamp - CHECKOUT - User: $user, Group: $group"
Add-Content -Path $logFile -Value $entry
```

## Troubleshooting

### User Creation Issues

```powershell
# Test local user management permissions
try {
    Get-LocalUser -Name "test" -ErrorAction Stop 2>$null
    Write-Output "Success: Can access local user management"
} catch {
    Write-Output "Error: Cannot access local user management"
}
```

### Group Assignment Issues

```powershell
# Verify target group exists
try {
    Get-LocalGroup -Name $env:group -ErrorAction Stop
    Write-Output "Success: Group '$env:group' exists"
} catch {
    Write-Output "Error: Group '$env:group' not found"  
}
```

### RDP Session Issues

```powershell
# Test RDP session management
try {
    $sessions = qwinsta 2>$null
    Write-Output "Success: Can query RDP sessions"
    Write-Output $sessions
} catch {
    Write-Output "Error: Cannot query RDP sessions"
}
```

### Permission Verification

```powershell
# Check current user privileges
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($currentUser)
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Output "Running as Administrator: $isAdmin"
```

## Best Practices

1. **Environment Validation**: Always validate environment variables before processing
2. **Error Logging**: Log all operations with sufficient detail for troubleshooting
3. **Cleanup Automation**: Implement automated cleanup processes with appropriate scheduling
4. **Security Review**: Regular review of temporary accounts and access patterns
5. **Password Policy**: Ensure generated passwords meet organizational security requirements
6. **Session Management**: Monitor and control RDP sessions for temporary users
7. **Audit Trail**: Maintain comprehensive audit logs for compliance requirements
8. **Testing**: Thoroughly test in non-production environments before deployment

## Limitations

- **Local Scope Only**: Creates local users only (not domain users)
- **Single Server**: Scripts operate on local machine only
- **Windows Only**: Designed for Windows operating systems
- **PowerShell Dependency**: Requires PowerShell and appropriate modules
- **Admin Rights**: Requires administrator privileges for user management
