# Kill RDP Sessions

This directory contains scripts for terminating active Remote Desktop Protocol (RDP) sessions across multiple servers based on group membership mappings.

## Overview

The `KillRDPSessions.ps1` script provides automated termination of RDP sessions for users across a fleet of servers. It uses a CSV mapping file to determine which servers a user should be logged off from based on their group membership.

## Files

- **`KillRDPSessions.ps1`** - Main PowerShell script for terminating RDP sessions

## How It Works

1. **Environment Variables**: Reads user identity and group membership from environment variables
2. **CSV Mapping**: Reads server-to-group mappings from a centralized CSV file
3. **Session Termination**: Uses the `Get-ActiveSession` module to terminate sessions on mapped servers

## Prerequisites

### PowerShell Module

```powershell
Install-Module -Name Get-ActiveSession
```

The script requires the `Get-ActiveSession` PowerShell module from PowerShell Gallery:

- **Module Source**: [PowerShell Gallery - Get-ActiveSession](https://www.powershellgallery.com/packages/Get-ActiveSession/1.0.4)
- **Version**: 1.0.4 or later

### CSV Mapping File

The script expects a CSV file at the following location:
```
C:\Program Files (x86)\Britive Inc\Britive Broker\scripts\mappings.csv
```

**CSV Format**:

```csv
Group,Server
Group A,Server A
Group B,Server B
Group B,Server C
```

Each row maps a group to a server. Multiple servers can be mapped to the same group.

## Environment Variables

The script uses the following environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `$env:user` | User identity (UPN format) | `jdoe@domain.com` |
| `$env:group` | User's group membership | `Group A` |

## Usage

The script is typically executed automatically by access management systems during user checkout/revocation processes:

```powershell
# Set environment variables (usually done by calling system)
$env:user = "jdoe@domain.com"
$env:group = "Group A"

# Execute the script
.\KillRDPSessions.ps1
```

## Process Flow

1. **User Identification**: Extracts username without domain suffix from `$env:user`
2. **Group Lookup**: Identifies the user's group from `$env:group`
3. **Server Mapping**: Reads CSV file to find all servers mapped to the user's group
4. **Session Termination**: For each mapped server, calls `Start-PSCRemoteLogoff` to terminate the user's active sessions

## Error Handling

- **Missing CSV File**: Script exits with error if mapping file is not found
- **Module Import**: Requires `Get-ActiveSession` module to be installed
- **Remote Connectivity**: Depends on network connectivity to target servers

## Security Considerations

- **Execution Rights**: Script requires appropriate privileges to terminate remote sessions
- **Network Access**: Must have network connectivity to target servers
- **CSV File Security**: Mapping file should be secured and regularly audited
- **Logging**: All session termination activities should be logged for audit purposes

## Integration

This script is designed to integrate with:

- **Britive Access Broker**: References Britive-specific file paths
- **Privileged Access Management (PAM)** systems
- **Just-In-Time (JIT)** access workflows
- **Security compliance** and incident response processes

## Use Cases

- **Access Revocation**: Immediately terminate sessions when user access is revoked
- **Security Incidents**: Emergency session termination during security events  
- **Compliance**: Ensure users don't maintain active sessions beyond authorized time
- **Group-Based Management**: Automatically manage sessions based on group membership changes

## Troubleshooting

### Common Issues

1. **Module Not Found**: Install the `Get-ActiveSession` module
2. **CSV File Missing**: Verify the mapping file exists and has correct permissions
3. **Network Connectivity**: Ensure network access to target servers
4. **Permission Denied**: Verify sufficient privileges for remote session management

### Logs and Debugging

Check PowerShell execution logs and Windows Event Logs on both the executing machine and target servers for detailed error information.
