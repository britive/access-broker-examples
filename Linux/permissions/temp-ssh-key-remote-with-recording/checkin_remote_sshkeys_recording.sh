#!/bin/bash

# ==============================
# Configurable Variables
# ==============================
USER_EMAIL=${BRITIVE_USER_EMAIL:-"test@example.com"}
USERNAME="${USER_EMAIL%%@*}"
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"

TARGET_USER=${USERNAME}
TARGET_GROUP=${USERNAME}
SUDO_FLAG=${BRITIVE_SUDO:-"0"}
HOME_ROOT=${BRITIVE_HOME_ROOT:-"home"}

REMOTE_USER="ubuntu"  # default AWS/Ubuntu user
REMOTE_HOST="$BRITIVE_REMOTE_HOST"
REMOTE_KEY="/home/britivebroker/pc-ldap-linux.pem"  # <-- Path to your AWS PEM file

TRX=${TRX:-"britive-trx-id"}  # Transaction ID marker

# ===== Fail-fast checks =====
[[ -z "$REMOTE_HOST" ]] && { echo "ERROR: REMOTE_HOST is empty"; exit 1; }
[[ ! -f "$REMOTE_KEY" ]] && { echo "ERROR: SSH key not found at $REMOTE_KEY"; exit 1; }


# ==============================
# Remove public keys matching marker from authorized_keys on remote host
# ==============================
ssh -i "$REMOTE_KEY" -o IdentitiesOnly=yes "$REMOTE_USER@$REMOTE_HOST" bash -s <<EOF
set -euo pipefail

TARGET_USER="$TARGET_USER"
TARGET_GROUP="$TARGET_GROUP"
HOME_ROOT="$HOME_ROOT"
SSH_PATH=/"\$HOME_ROOT"/"\$TARGET_USER"/.ssh
AUTHORIZED_KEYS="\$SSH_PATH/authorized_keys"
MARKER="# britive-$TRX"
SUDO_FLAG="$SUDO_FLAG"


# --- Remove injected SSH keys ---
if sudo test -f "\$AUTHORIZED_KEYS"; then
  sudo grep -vF "\$MARKER" "\$AUTHORIZED_KEYS" | sudo tee "\$AUTHORIZED_KEYS.tmp" >/dev/null
  sudo mv "\$AUTHORIZED_KEYS.tmp" "\$AUTHORIZED_KEYS"
  sudo chmod 600 "\$AUTHORIZED_KEYS"
  sudo chown "\$TARGET_USER:\$TARGET_GROUP" "\$AUTHORIZED_KEYS"
  echo "Removed keys with marker \$MARKER for user \$TARGET_USER"
else
  echo "No authorized_keys file found for \$TARGET_USER"
fi

# --- Remove sudoers entry if created ---
if [ "\$SUDO_FLAG" != "0" ]; then
  if sudo test -f "/etc/sudoers.d/\$TARGET_USER"; then
    sudo rm -f "/etc/sudoers.d/\$TARGET_USER"
    echo "Removed sudoers entry for \$TARGET_USER"
  fi
fi

# --- Optionally delete the user ---
#if [ "\$DELETE_USER" = "1" ]; then
#  if id "\$TARGET_USER" &>/dev/null; then
#    sudo userdel -r "\$TARGET_USER" || true
#    echo "Deleted user \$TARGET_USER and home directory"
#  else
#    echo "User \$TARGET_USER does not exist"
#  fi
#fi
EOF