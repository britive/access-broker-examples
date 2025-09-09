# Windows Permissions Scripts

This directory contains various PowerShell scripts and configurations designed for managing Windows permissions, user access, and session control in enterprise environments. Each sub-directory serves a specific purpose in the access management workflow for the customers of Britive Access Broker.

## Directory Overview

### 📁 [`kill-rdp-sessions/`](./kill-rdp-sessions/)

**Purpose**: Terminate active RDP (Remote Desktop Protocol) sessions for users across multiple servers upon profile check-in.

**Scripts**:

- `KillRDPSessions.ps1` - Main script that reads server mappings from a profile checkout file and kills RDP sessions for a specific user on mapped servers

**Key Features**:

- Uses the `Get-ActiveSession` PowerShell module
- Reads server-to-group mappings from `C:\Program Files (x86)\Britive Inc\Britive Broker\scripts\mappings.csv`
- Automatically determines target servers based on user's group membership
- Extracts username without domain suffix for session termination

**Use Case**: Ideal for security compliance scenarios where active sessions need to be terminated immediately when access is revoked.

---

### 📁 [`local-admin-remote-server/`](./local-admin-remote-server/)

**Purpose**: Manage local group membership on remote Windows servers using PowerShell remoting. A domain user is granted local group membership, allowing user to make an RDP connection into the VM based on the allowed permissions of the granted group membership.

**Scripts**:

- `checkout.ps1` - Adds a user to a specified local group on a remote server
- `checkin.ps1` - Removes a user from a specified local group on a remote server

**Key Features**:

- Uses `Invoke-Command` for remote PowerShell execution
- Supports adding/removing users to any local group (e.g., "Administrators", "Remote Desktop Users")
- Handles UPN (User Principal Name) format usernames
- Comprehensive error handling and logging

**Environment Variables Used**:

Are set by Britive at time of the profile checkout

- `$env:user` - User UPN (e.g., "jdoe@domain.com")
- `$env:target` - Target server FQDN (e.g., "server01.domain.com")
- `$env:group` - Target local group name (e.g., "Administrators")

**Use Case**: Perfect for just-in-time (JIT) access scenarios where users need temporary administrative or specific group access on remote servers.

---

### 📁 [`remote-temp-admin/`](./remote-temp-admin/)

**Purpose**: Simplified temporary administrator access management for remote servers, specifically focused on the Administrators group.

**Scripts**:

- `RemoteAdmin-checkout.ps1` - Grants temporary administrator access to a user on a remote server
- `RemoteAdmin-checkin.ps1` - Revokes administrator access from a user on a remote server

**Key Features**:

- Specifically targets the "Administrators" local group
- Constructs user identity from email and domain environment variables
- Uses PowerShell remoting for secure remote execution
- Streamlined for administrator-only access scenarios

**Environment Variables Used**:

Are set by Britive at time of the profile checkout

- `$env:email` - User's email address (extracts username before '@' and before any '-')
- `$env:domain` - Target domain
- `$env:target` - Target server for administrative access

**Use Case**: Designed for privileged access management (PAM) systems where administrators need temporary elevated access to specific servers.

---

### 📁 [`session-recording/`](./session-recording/)

**Purpose**: Deploy Apache Guacamole for session recording and remote desktop gateway functionality.

**Components**:

- `docker-compose.yml` - Docker Compose configuration for Apache Guacamole stack
- `README.md` - Comprehensive installation and configuration guide
- `init/001-create-schema.sql` - Database initialization schema

**Key Features**:

- **Apache Guacamole**: Clientless remote desktop gateway supporting RDP, VNC, and SSH
- **MySQL Database**: Persistent storage for connection configurations and user data
- **Docker-based Deployment**: Easy deployment and management using containers
- **Session Recording Capability**: Built-in session recording for compliance and auditing

**Stack Components**:

- `guacamole/guacd` - Guacamole proxy daemon
- `guacamole/guacamole` - Web application and user interface
- `mysql:5.7` - Database backend for configuration storage

**Use Case**: Essential for organizations requiring session recording, centralized remote access management, and compliance with security auditing requirements.

---

### 📁 [`temp-local-user/`](./temp-local-user/)

**Purpose**: Create and manage temporary local user accounts with automatic password generation and cleanup.

**Scripts**:

- `checkout.ps1` - Creates temporary local user account with generated password and adds to specified group
- `checkin.ps1` - Removes temporary local user account and optionally terminates active RDP sessions

**Key Features**:

#### Checkout Process (`checkout.ps1`)

- **Automatic Password Generation**: Creates secure 12-character passwords with mixed case, numbers, and special characters
- **User Account Management**: Creates new users or resets passwords for existing users
- **Group Membership**: Automatically adds users to specified local groups
- **Credential Output**: Returns username and password for immediate use

#### Checkin Process (`checkin.ps1`)

- **RDP Session Termination**: Optional killing of active RDP sessions (controlled by `$env:killrdp`)
- **Complete User Cleanup**: Removes local user accounts entirely
- **Session Management**: Uses `qwinsta` and `Invoke-RDUserLogoff` for session control

**Environment Variables Used**:
Are set by Britive at time of the profile checkout

- `$env:email` - User's email (username extracted and sanitized)
- `$env:group` - Target local group for user membership
- `$env:killrdp` - Flag to control RDP session termination (optional)

**Security Features**:

- Username sanitization (removes non-alphanumeric characters)
- Secure password generation with multiple character sets
- Comprehensive error handling
- Automatic cleanup to prevent account proliferation

**Use Case**: Ideal for temporary contractor access, emergency access scenarios, or short-term project work where full domain accounts are not warranted.

---

## Common Patterns and Best Practices

### Environment Variable Usage

All scripts follow a consistent pattern of using environment variables for configuration:

- `$env:user` or `$env:email` for user identification
- `$env:target` for target server specification
- `$env:group` for group membership control
- `$env:domain` for domain specification

### Error Handling

Scripts implement comprehensive error handling with:

- Try-catch blocks for critical operations
- Descriptive error messages
- Graceful failure modes
- Proper exit codes

### PowerShell Remoting

Scripts utilizing remote execution follow security best practices:

- Use of `Invoke-Command` with script blocks
- Parameter passing to avoid script injection
- Proper error propagation from remote sessions

### Logging and Auditing

Scripts provide appropriate logging:

- Success/failure status reporting
- User and target identification in logs
- Timestamp implicit in PowerShell execution context

## Integration Considerations

These scripts are designed to integrate with:

- **Britive Access Broker**: Scripts reference Britive-specific paths and configurations
- **Privileged Access Management (PAM)** systems
- **Identity and Access Management (IAM)** platforms
- **Security Information and Event Management (SIEM)** systems for audit logging

## Security Considerations

- All scripts should be executed with appropriate privileges and must be verified and updated before use in production
- PowerShell execution policy must allow script execution
- Network connectivity and appropriate firewall rules required for remote operations
- Regular review of created temporary accounts and active sessions recommended
- Sensitive credentials (especially in session-recording configuration) should be properly secured

## Prerequisites

- PowerShell 5.1 or later
- Windows Remote Management (WinRM) enabled for remote operations
- Appropriate PowerShell modules installed:
  - `Get-ActiveSession` (for RDP session management)
  - Built-in `Microsoft.PowerShell.LocalAccounts` module
- Network connectivity between executing machine (the Broker) and target servers
- Sufficient privileges for user and group management operations
