# IBM AS400 Custom Function Provisioning Scripts

This directory contains shell scripts for managing user permissions on IBM AS400 systems through Britive's access broker. The scripts provide automated provisioning and deprovisioning of user authorizations and group memberships.

## Core Components

### Environment Variables
All scripts require the following environment variables:
- `BRITIVE_AS400_USER` - Target user for permission operations
- `BRITIVE_AS400_HOST` - AS400 system hostname
- `BRITIVE_ADMIN_USER` - Administrative user for SSH connections
- `BRITIVE_SSH_KEY_PATH` - Path to SSH private key (defaults to `/home/britivebroker/.ssh/id-rsa`)

### Common Infrastructure
- **Environment Validation**: All scripts include robust validation of required environment variables
- **SSH Connection Management**: Secure SSH connections with proper error handling and timeout controls
- **Error Handling**: Comprehensive error reporting and cleanup mechanisms

## Script Functions

### `add_authorization_checkout.sh`
**Purpose**: Grants authorization permissions to a user on the AS400 system

**Required Variables**:
- `BRITIVE_USER_AS400_AUTH` - Authorization level to grant

**Core Function**: Executes `BRTVADDAUT` program to add user authorization

### `add_group_checkout.sh`
**Purpose**: Adds group membership for a user on the AS400 system

**Required Variables**:
- `BRITIVE_USER_AS400_GROUP` - Group name to add user to

**Core Function**: Executes `BRTVADDGRP` program to add group membership

### `remove_authorization_checkin.sh`
**Purpose**: Revokes authorization permissions from a user on the AS400 system

**Required Variables**:
- `BRITIVE_USER_AS400_AUTH` - Authorization level to revoke

**Core Function**: Executes `BRTVRMVAUT` program to remove user authorization

### `remove_group_checkin.sh`
**Purpose**: Removes group membership for a user on the AS400 system

**Required Variables**:
- `BRITIVE_USER_AS400_GROUP` - Group name to remove user from

**Core Function**: Executes `BRTVRMVGRP` program to remove group membership

## Architecture

The scripts follow a checkout/checkin pattern:
- **Checkout scripts** (`add_*`) provision access by granting permissions
- **Checkin scripts** (`remove_*`) deprovision access by revoking permissions

Each script connects to the AS400 system via SSH and executes custom programs (`BRTVADDAUT`, `BRTVADDGRP`, `BRTVRMVAUT`, `BRTVRMVGRP`) located in the `FOLD` library to manage user permissions.

## Security Features

- SSH key validation and permission checks
- Secure connection parameters (no host key checking, batch mode)
- Connection timeouts to prevent hanging connections
- Comprehensive error logging and exit code handling