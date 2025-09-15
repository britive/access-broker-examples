#!/bin/bash

# IBM AS400 Authorization Checkin Script
# This script removes authorization for a user on IBM AS400 system
# Required environment variables: BRITIVE_AS400_USER, BRITIVE_USER_AS400_AUTH

set -euo pipefail  # Enable strict error handling: exit on error, undefined vars, pipe failures

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

echo "Starting AS400 authorization checkin process"

# Validate required environment variables
if [[ -z "${BRITIVE_AS400_USER:-}" ]]; then
    echo "ERROR: BRITIVE_AS400_USER environment variable is not set" >&2
    exit 1
fi

if [[ -z "${BRITIVE_USER_AS400_AUTH:-}" ]]; then
    echo "ERROR: BRITIVE_USER_AS400_AUTH environment variable is not set" >&2
    exit 1
fi

# Assign variables with proper syntax
USER="$BRITIVE_AS400_USER"
AUTH="$BRITIVE_USER_AS400_AUTH"

# Validate SSH key exists (use environment variable or default path)
SSH_KEY_PATH="${BRITIVE_SSH_KEY_PATH:-/home/britivebroker/.ssh/id-rsa}"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "ERROR: SSH key not found at $SSH_KEY_PATH" >&2
    exit 1
fi

# Validate SSH key permissions
if [[ $(stat -c %a "$SSH_KEY_PATH") != "600" ]]; then
    echo "WARNING: SSH key permissions are not 600, this may cause SSH to fail" >&2
fi

echo "Connecting to AS400 system to remove authorization for user: $USER"
echo "Authorization level: $AUTH"

# Execute SSH command with proper error handling
if ssh -i "$SSH_KEY_PATH" \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=30 \
       -o BatchMode=yes \
       brtvadm@it4m602r \
       "system 'CALL PGM(FOLD/BRTVRMVAUT) PARM(\"$USER\", \"$AUTH\")'"; then
    echo "SUCCESS: Authorization successfully removed for user $USER"
else
    echo "ERROR: Failed to remove authorization for user $USER" >&2
    exit 1
fi

echo "AS400 authorization checkin completed successfully"