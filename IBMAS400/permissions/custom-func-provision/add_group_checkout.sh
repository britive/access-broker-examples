#!/bin/bash

# IBM AS400 Group Membership Checkout Script
# This script adds group membership for a user on IBM AS400 system
# Required environment variables: BRITIVE_AS400_USER, BRITIVE_USER_AS400_GROUP, BRITIVE_AS400_HOST, BRITIVE_ADMIN_USER

set -euo pipefail  # Enable strict error handling: exit on error, undefined vars, pipe failures

# Consolidated validation function
validate_environment() {
    local required_vars=("$@")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "ERROR: Missing required environment variables: ${missing_vars[*]}" >&2
        exit 1
    fi
}

echo "Starting AS400 group membership checkout process"

# Validate required environment variables
validate_environment "BRITIVE_AS400_USER" "BRITIVE_USER_AS400_GROUP" "BRITIVE_AS400_HOST" "BRITIVE_ADMIN_USER"


# Assign variables with proper syntax
USER="$BRITIVE_AS400_USER"
GROUP="$BRITIVE_USER_AS400_GROUP"
HOST="$BRITIVE_AS400_HOST"
ADMN="$BRITIVE_ADMIN_USER"
SSH_KEY_PATH="${BRITIVE_SSH_KEY_PATH:-/home/britivebroker/.ssh/id-rsa}"

# Function to handle script exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "ERROR: Script failed with exit code $exit_code" >&2
    fi
    exit $exit_code
}

# Set up error handling
trap cleanup EXIT

# Validate SSH key exists (use environment variable or default path)

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "ERROR: SSH key not found at $SSH_KEY_PATH" >&2
    exit 1
fi

# Validate SSH key permissions
if [[ $(stat -c %a "$SSH_KEY_PATH") != "600" ]]; then
    echo "WARNING: SSH key permissions are not 600, this may cause SSH to fail" >&2
fi

echo "Connecting to AS400 system to add group membership for user: $USER"
echo "Group Membership: $GROUP"

# Execute SSH command with proper error handling
if ssh -i "$SSH_KEY_PATH" \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=30 \
       -o BatchMode=yes \
       $ADMN@$HOST \
       "system 'CALL PGM(FOLD/BRTVADDGRP) PARM(\"$USER\", \"$GROUP\")'"; then
    echo "SUCCESS: Group membership successfully added for user $USER"
else
    echo "ERROR: Failed to add group membership for user $USER" >&2
    exit 1
fi

echo "AS400 group membership checkout completed successfully"