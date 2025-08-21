# Britive Apache Guacamole Integration Scripts

This repository contains two bash scripts that provide temporary SSH access through Apache Guacamole proxy with session recording capabilities. These scripts integrate with the Britive Access Broker system to create ephemeral, monitored connections to remote Linux hosts.

## Overview

The scripts implement a just-in-time (JIT) access pattern with proxied connections where:

1. **checkout_remote_sshkeys_recording.sh** - Creates temporary SSH access and generates a Guacamole authentication token
2. **checkin_remote_sshkeys_recording.sh** - Revokes SSH access and cleans up permissions

## Key Features

- **Proxied Access**: All connections route through Apache Guacamole proxy
- **Session Recording**: Automatic recording of all SSH sessions
- **Token Authentication**: JSON Web Token-based authentication with HMAC-SHA256 signing
- **Ephemeral Access**: Temporary SSH keys with transaction-specific markers
- **Audit Trail**: Recorded sessions with timestamped filenames

## Scripts Description

### checkout_remote_sshkeys_recording.sh

**Purpose**: Creates temporary SSH access and generates a Guacamole authentication token for proxied, recorded connections.

**Key Functions**:

- Validates environment and retrieves encryption keys from AWS Secrets Manager
- Generates temporary RSA SSH key pairs
- Creates user accounts on remote hosts with optional sudo privileges
- Sets up SSH directory structure and installs public keys
- Creates JSON configuration for Guacamole connection
- Signs and encrypts the configuration using HMAC-SHA256 and AES-128-CBC
- Returns authentication token and Guacamole URL

**Process Flow**:

1. Validate environment variables and retrieve secret key from AWS
2. Generate SSH keypair in temporary directory
3. Create/configure user account on remote host
4. Install SSH public key with transaction marker
5. Build JSON connection configuration with recording parameters
6. Sign JSON payload with HMAC-SHA256
7. Encrypt signed payload with AES-128-CBC
8. Return base64-encoded token and Guacamole URL

### checkin_remote_sshkeys_recording.sh

**Purpose**: Revokes SSH access by removing SSH keys and cleaning up sudo permissions.

**Key Functions**:

- Removes SSH keys matching the transaction marker
- Optionally removes sudo privileges
- Maintains proper file permissions and ownership
- Provides option to delete user accounts (commented out by default)

**Process Flow**:

1. Connect to remote host
2. Remove SSH keys with specific transaction markers
3. Remove sudoers entries if sudo access was granted
4. Restore proper file permissions
5. Optionally delete user accounts (disabled by default)

## Configuration Variables

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BRITIVE_USER_EMAIL` | `test@example.com` | User email for SSH key comment and username generation |
| `BRITIVE_REMOTE_HOST` | (required) | Target remote host IP address or hostname |
| `TRX` | `britive-trx-id` | Transaction ID for tracking access sessions |
| `BRITIVE_SUDO` | `0` | Grant sudo privileges (0=no, 1=yes) |
| `BRITIVE_HOME_ROOT` | `home` | Root directory for user home directories |
| `json_secret_key` | (required) | AWS Secrets Manager secret ID containing encryption key |
| `connection_name` | (required) | Name for the Guacamole connection |
| `expiration` | (required) | Token expiration time in seconds |
| `recording_path` | `/home/guacd/recordings` | Path for session recordings |
| `url` | (required) | Base URL for Guacamole web interface |
| `GUAC_DATE` | (auto-generated) | Date stamp for recording filenames |
| `GUAC_TIME` | (auto-generated) | Time stamp for recording filenames |

### Static Configuration

**SSH Keys**:

- Checkout: `/ssh/key-linux.pem`
- Checkin: `/home/britivebroker/pc-ldap-linux.pem`

**Remote Connection User**: `ubuntu` (default AWS/Ubuntu user)

## Prerequisites

### Broker Host Requirements

**Software Dependencies**:

- `bash` shell
- `ssh` client and `scp` command
- `ssh-keygen` utility
- `openssl` CLI tools
- `jq` JSON processor
- `aws` CLI v2
- Standard utilities: `mktemp`, `date`, `tr`

**AWS Configuration**:

- AWS CLI configured with appropriate credentials
- Access to AWS Secrets Manager in `us-west-2` region
- Secret containing 32-character hexadecimal encryption key

**Files & Permissions**:

- SSH private key files with `600` permissions
- Scripts executable (`chmod +x`)

**Network Access**:

- SSH connectivity to target remote hosts
- HTTPS access to AWS Secrets Manager API

### Apache Guacamole Server Requirements

**Guacamole Configuration**:

- Guacamole server with JSON token authentication enabled
- Shared secret key (32 hex characters) configured
- Session recording enabled and properly configured
- Recording directory accessible and writable

**Recording Setup**:

- Recording directory (`/home/guacd/recordings` by default) must exist
- Proper permissions for guacd daemon to write recordings
- Sufficient disk space for session recordings

### Remote Host Requirements

**Initial Setup User** (ubuntu):

- SSH key-based authentication configured
- Sudo privileges for user management operations

**Required Sudo Capabilities**:

  ```bash
  # User and group management
  sudo useradd, sudo usermod, sudo userdel
  sudo groupadd, sudo getent
  sudo id

  # File and directory operations
  sudo mkdir, sudo chmod, sudo chown
  sudo touch, sudo rm, sudo mv
  sudo test, sudo tee, sudo bash -c

  # System configuration
  sudo grep (for authorized_keys manipulation)
  ```

**System Requirements**:

- Standard Linux user management utilities
- SSH daemon running and accessible
- Home directory structure supports user creation

## Secret Management

### AWS Secrets Manager Setup

The encryption key must be stored in AWS Secrets Manager with the following format:

  ```json
  {
    "key": "0123456789abcdef0123456789abcdef"
  }
  ```

**Key Requirements**:

- Exactly 32 hexadecimal characters (16 bytes)
- Matches the secret configured in Guacamole
- Stored in `us-west-2` region (configurable in script)

### Key Security

- Encryption uses AES-128-CBC with zero IV (consider random IV for production)
- HMAC-SHA256 provides message authentication
- Keys should be rotated periodically
- Access to AWS Secrets Manager should be restricted

## Session Recording

### Recording Features

**Automatic Recording**: All SSH sessions through Guacamole are automatically recorded

**Recording Format**: Sessions are saved in Guacamole's native format

**Filename Convention**:

  ```
  ${GUAC_DATE}-${GUAC_TIME}-${USER_EMAIL}-${USERNAME}-${CONNECTION_NAME}
  ```

Example: `20250820-143022-user@company.com-user-production-server`

**Storage Location**: Configurable via `recording_path` variable (default: `/home/guacd/recordings`)

### Recording Management

**Retention**: Configure retention policies at the Guacamole server level

**Playback**: Recordings can be played back through Guacamole web interface

**Export**: Recordings can be exported or archived as needed

## Security Considerations

### Strengths

- **Proxied Access**: All connections route through monitored Guacamole proxy
- **Complete Session Recording**: Full audit trail of all user activities
- **Encrypted Tokens**: Authentication tokens are encrypted and signed
- **Temporary Keys**: SSH keys are generated fresh and removed after use
- **Time-Limited Access**: Tokens have configurable expiration times
- **Transaction Tracking**: Each session has unique transaction markers

### Security Notes

- **Zero IV**: Current implementation uses zero IV for AES encryption (consider random IV)
- **Key Management**: Secret keys are stored in AWS Secrets Manager
- **Network Security**: Ensure Guacamole server is properly secured and accessible only via HTTPS
- **Recording Security**: Session recordings contain sensitive data and should be secured appropriately
- **User Persistence**: User accounts remain on remote hosts (only SSH access is revoked)
- **Sudo Cleanup**: Sudo privileges are removed during checkin

### Recommendations

1. **Use HTTPS**: Always access Guacamole over HTTPS
2. **Rotate Keys**: Regularly rotate encryption keys in Secrets Manager
3. **Secure Recordings**: Implement appropriate access controls for recording storage
4. **Monitor Access**: Review Guacamole access logs and session recordings
5. **Network Isolation**: Consider network segmentation for Guacamole infrastructure

## Token Structure

### JSON Payload Format

```json
{
  "username": "user@company.com",
  "expires": "1692547200000",
  "connections": {
    "connection-name": {
      "protocol": "ssh",
      "parameters": {
        "hostname": "192.168.1.100",
        "port": "22",
        "username": "targetuser",
        "private-key": "-----BEGIN RSA PRIVATE KEY-----\\n...",
        "recording-path": "/home/guacd/recordings",
        "recording-name": "20250820-143022-user@company.com-user-connection"
      }
    }
  }
}
```

### Token Generation Process

1. **JSON Creation**: Build connection configuration JSON
2. **HMAC Signing**: Sign JSON with HMAC-SHA256 using secret key
3. **AES Encryption**: Encrypt signed payload with AES-128-CBC
4. **Base64 Encoding**: Encode encrypted data as base64
5. **URL Encoding**: URL-encode the final token

## Troubleshooting

### Common Issues

1. **Secret Key Errors**:
   - Verify AWS CLI configuration and permissions
   - Ensure secret exists in correct region
   - Check secret key format (32 hex characters)

2. **SSH Connection Failures**:
   - Verify SSH key file paths and permissions
   - Check network connectivity to remote hosts
   - Ensure remote user has proper sudo privileges

3. **Guacamole Authentication Failures**:
   - Verify secret key matches Guacamole configuration
   - Check token expiration times
   - Ensure Guacamole server is accessible

4. **Recording Issues**:
   - Verify recording directory exists and is writable
   - Check disk space for recording storage
   - Ensure guacd service has proper permissions

### Debugging

**Enable Verbose Output**:

- Remove `-q` flags from SSH/SCP commands
- Add `set -x` to scripts for detailed execution traces

**Check Logs**:

- Remote host: `/var/log/auth.log` or `/var/log/secure`
- Guacamole: Check guacamole and guacd service logs
- AWS: Check CloudTrail for Secrets Manager access

**Validate Components**:

- Test SSH connectivity manually
- Verify AWS Secrets Manager access
- Check Guacamole server configuration

## Integration with Britive

These scripts are designed to be called by the Britive Access Broker with environment variables set automatically based on:

- User access requests
- Target system configurations
- Organizational policies
- Recording requirements

The integration provides a complete audit trail from access request through session recording and cleanup.
