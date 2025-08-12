#!/bin/bash

# ==============================
# Variables
# ==============================
USER_EMAIL=${BRITIVE_USER_EMAIL:-"test@example.com"}
USERNAME="${USER_EMAIL%%@*}"
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"

TRX=${TRX:-"britive-trx-id"}  # Transaction ID of the checkout
USER=${USERNAME}
HOME_ROOT=${BRITIVE_HOME_ROOT:-"home"}
REMOTE_USER=${REMOTE_USER:-"ec2-user"}  # Remote connection user that the britive broker will use.
REMOTE_HOST=${HOST}

REMOTE_KEY="/home/britivebroker/MYKEY.pem"  # <-- Path to your AWS PEM file


# ==============================
# Remove public keys matching marker from authorized_keys on remote host
# ==============================
ssh -i "$REMOTE_KEY" -o IdentitiesOnly=yes "$REMOTE_USER@$REMOTE_HOST" bash -s <<EOF
set -e

TARGET_USER="$USER"
HOME_ROOT="$HOME_ROOT"
SSH_PATH=/${HOME_ROOT}/\${TARGET_USER}/.ssh
AUTHORIZED_KEYS="\$SSH_PATH/authorized_keys"
MARKER="# britive-$TRX"

if sudo test -f "\$AUTHORIZED_KEYS"; then
  sudo grep -vF "\$MARKER" "\$AUTHORIZED_KEYS" | sudo tee "\$AUTHORIZED_KEYS.tmp" >/dev/null
  sudo mv "\$AUTHORIZED_KEYS.tmp" "\$AUTHORIZED_KEYS"
  sudo chmod 600 "\$AUTHORIZED_KEYS"
  sudo chown "\$TARGET_USER:\$TARGET_USER" "\$AUTHORIZED_KEYS"
  echo "✅ Removed keys with marker \$MARKER for user \$TARGET_USER"
else
  echo "⚠️ No authorized_keys file found for \$TARGET_USER"
fi
EOF