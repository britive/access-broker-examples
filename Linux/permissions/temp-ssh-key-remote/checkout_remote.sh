#!/bin/bash

# ==============================
# Configurable Variables
# ==============================
USER_EMAIL=${BRITIVE_USER_EMAIL:-"test@example.com"}
USERNAME="${USER_EMAIL%%@*}"
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"

TRX=${TRX:-"britive-trx-id"}  # Transaction ID of the checkout
USER=${USERNAME}
GROUP=${USERNAME}
SUDO=${BRITIVE_SUDO:-"0"}
HOME_ROOT=${BRITIVE_HOME_ROOT:-"home"}
REMOTE_USER=${REMOTE_USER:-"ec2-user"}  # default AWS user
REMOTE_HOST=${HOST}

REMOTE_KEY="/home/britivebroker/MYKEY.pem"  # <-- Path to your AWS PEM file


# ==============================
# Generate SSH keypair in temp location
# ==============================
TMP_DIR=$(mktemp -d)
SSH_KEY_LOCAL="$TMP_DIR/britive-id_rsa"
SSH_KEY_PUB="$TMP_DIR/britive-id_rsa.pub"

ssh-keygen -q -N '' -t rsa -C "$USER_EMAIL" -f "$SSH_KEY_LOCAL"
#echo "✅ Generated new keypair (not stored permanently)"

# ==============================
# Create user and setup on remote server
# ==============================
ssh -i "$REMOTE_KEY" -o IdentitiesOnly=yes "$REMOTE_USER@$REMOTE_HOST" bash -s <<EOF
set -e

USER="$USER"
GROUP="$GROUP"
SUDO="$SUDO"
HOME_ROOT="$HOME_ROOT"
SSH_PATH=/${HOME_ROOT}/\${USER}/.ssh

if ! id "\$USER" &>/dev/null; then
  sudo useradd -m "\$USER"
fi

sudo mkdir -p "\$SSH_PATH"
sudo chmod 700 "\$SSH_PATH"
sudo chown "\$USER:\$GROUP" "\$SSH_PATH"

if [ "\$SUDO" != "0" ]; then
  echo "\$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/\$USER >/dev/null
  sudo chmod 440 /etc/sudoers.d/\$USER
fi
EOF

# ==============================
# Append public key with TRX marker and push it to remote
# ==============================
PUB_KEY_WITH_MARKER="$(cat "$SSH_KEY_PUB") # britive-$TRX"

echo "$PUB_KEY_WITH_MARKER" > "$TMP_DIR/britive-id_rsa_marker.pub"

scp -q -i "$REMOTE_KEY" -o IdentitiesOnly=yes "$TMP_DIR/britive-id_rsa_marker.pub" "$REMOTE_USER@$REMOTE_HOST:/tmp/britive-id_rsa_marker.pub"

ssh -i "$REMOTE_KEY" -o IdentitiesOnly=yes "$REMOTE_USER@$REMOTE_HOST" bash -s <<EOF
set -e

USER="$USER"
HOME_ROOT="$HOME_ROOT"
SSH_PATH=/${HOME_ROOT}/\${USER}/.ssh

sudo bash -c "cat /tmp/britive-id_rsa_marker.pub >> \$SSH_PATH/authorized_keys"
sudo rm -f /tmp/britive-id_rsa_marker.pub
sudo chmod 600 "\$SSH_PATH/authorized_keys"
sudo chown "\$USER:\$USER" "\$SSH_PATH/authorized_keys"
EOF

# ==============================
# Output private key in JSON format
# ==============================

# Function to escape JSON string properly
json_escape() {
    local input="$1"
    # Escape backslashes first, then double quotes, then newlines and other control chars
    printf '%s' "$input" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/\r/\\r/g' | sed 's/\t/\\t/g'
}

# Read the private key and escape it for JSON
SSH_KEY_ESCAPED=$(json_escape "$(cat "$SSH_KEY_LOCAL")")

# Output as clean JSON with proper formatting
printf '{"pemContent":"%s"}\n' "$SSH_KEY_ESCAPED"

rm -rf "$TMP_DIR"

#echo "✅ User $USER created on $REMOTE_HOST with public key marker britive-$TRX"
#echo "🔑 Private key above — save it securely!"