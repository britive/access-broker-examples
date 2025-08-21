# Britive Remote Access Management Scripts

This repository contains two bash scripts that work together to provide temporary SSH access to remote Linux hosts through the Britive Access Broker system.

## Overview

The scripts implement a just-in-time (JIT) access pattern where:

1. **checkout_remote.sh** - Grants temporary SSH access by creating users and SSH keys
2. **checkin_remote.sh** - Revokes access by removing SSH keys and cleaning up

## Scripts Description

### checkout_remote.sh

**Purpose**: Grants temporary SSH access to a remote Linux host by creating a user account and setting up SSH key-based authentication.

**Key Functions**:

- Generates a temporary RSA SSH key pair
- Creates a user account on the remote host (if it doesn't exist)
- Sets up SSH directory structure with proper permissions
- Optionally grants sudo privileges to the user
- Installs the public key with a transaction-specific marker
- Returns the private key for immediate use
- Cleans up temporary files

**Process Flow**:

1. Generate SSH keypair in temporary directory
2. Connect to remote host and create user account
3. Set up `.ssh` directory with proper permissions
4. Optionally configure sudo access
5. Transfer and install public key with transaction marker
6. Output private key to stdout
7. Clean up temporary files

### checkin_remote.sh

**Purpose**: Revokes SSH access by removing the SSH keys associated with a specific transaction ID.

**Key Functions**:

- Connects to the remote host
- Identifies SSH keys with the specific transaction marker
- Removes matching keys from `authorized_keys` file
- Maintains file permissions and ownership

**Process Flow**:

1. Connect to remote host
2. Filter out SSH keys matching the transaction marker
3. Update `authorized_keys` file
4. Restore proper file permissions

## Configuration Variables

Both scripts use the following environment variables (with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `BRITIVE_USER_EMAIL` | `test@example.com` | Email address used for SSH key comment and username generation |
| `TRX` | `britive-trx-id` | Transaction ID for tracking this access session |
| `BRITIVE_SUDO` | `0` | Whether to grant sudo privileges (0=no, 1=yes) |
| `BRITIVE_HOME_ROOT` | `home` | Root directory for user home directories |
| `REMOTE_USER` | `ec2-user` | Username for initial connection to remote host |
| `HOST` | (required) | Target remote host IP address or hostname |

**Static Configuration** (requires manual setup):
- `REMOTE_KEY`: Path to SSH private key file (`/home/britivebroker/MYKEY.pem`)

## Prerequisites

### Broker Host Requirements

The host running these scripts (Britive broker) needs:

**Software**:
- `bash` shell
- `ssh` client
- `scp` command
- `ssh-keygen` utility
- `mktemp` command

**Files & Permissions**:

- SSH private key file at `/home/britivebroker/MYKEY.pem` with `600` permissions
- Scripts executable (`chmod +x checkout_remote.sh checkin_remote.sh`)

**Network Access**:

- SSH connectivity (port 22) to target remote hosts
- Outbound network access to target hosts

### Remote Host Requirements

**Initial Setup User** (e.g., `ec2-user`):

- Must exist on the remote host
- SSH key-based authentication configured
- Sudo privileges for user management commands

**Required Sudo Capabilities** for the initial connection user:
```bash
# User management
sudo useradd
sudo id

# Directory and file operations
sudo mkdir
sudo chmod
sudo chown
sudo test
sudo mv
sudo rm

# File content operations
sudo tee
sudo bash -c
sudo grep
```

**System Requirements**:

- Standard Linux user management utilities
- SSH daemon running and accessible
- Proper filesystem permissions for home directory creation


## Security Considerations

**Strengths**:

- Temporary access with automatic cleanup capability
- SSH key pairs are generated fresh for each session
- Transaction-specific markers prevent accidental key removal
- Private keys are not stored permanently on the broker
- User accounts persist but SSH access is revoked

**Important Notes**:

- The user account remains on the remote host after checkin (only SSH keys are removed)
- Sudo privileges (if granted) remain until manually removed
- Private key is output to stdout - handle securely
- SSH private key file on broker must be protected (600 permissions)

## Troubleshooting

**Common Issues**:

1. **Permission Denied**: Ensure the broker's SSH key has proper permissions and the remote user has sudo access
2. **User Already Exists**: Script handles existing users gracefully
3. **Network Connectivity**: Verify SSH access from broker to remote host
4. **Missing Dependencies**: Ensure all required utilities are installed

**Debugging**:

- Remove `-q` flags from SSH/SCP commands for verbose output
- Check remote host logs: `/var/log/auth.log` or `/var/log/secure`
- Verify environment variables are set correctly

## Integration with Britive

These scripts are designed to be called by the Britive Access Broker with appropriate environment variables set automatically based on the access request and target system configuration.
