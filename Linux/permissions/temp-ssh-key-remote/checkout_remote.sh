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
CONVERT_TO_PPK=${CONVERT_TO_PPK:-"0"}  # Set to "1" to include PPK format in output

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

# Prepare PEM content as single line
PEM_SINGLE_LINE="$(tr '\n' '\\' < "$SSH_KEY_LOCAL" | sed 's/\\/\\n/g')"

# Convert to PPK if requested
if [ "$CONVERT_TO_PPK" = "1" ]; then
    # Check if puttygen is available
    if command -v puttygen >/dev/null 2>&1; then
        PPK_FILE="$TMP_DIR/britive-id_rsa.ppk"
        puttygen "$SSH_KEY_LOCAL" -o "$PPK_FILE" -O private >/dev/null 2>&1
        
        if [ -f "$PPK_FILE" ]; then
            PPK_SINGLE_LINE="$(tr '\n' '\\' < "$PPK_FILE" | sed 's/\\/\\n/g')"
            # Output JSON with both PEM and PPK
            jq -n --arg pemContent "$PEM_SINGLE_LINE" --arg ppkContent "$PPK_SINGLE_LINE" '{pemContent: $pemContent, ppkContent: $ppkContent}'
        else
            echo "Warning: PPK conversion failed, outputting PEM only" >&2
            jq -n --arg pemContent "$PEM_SINGLE_LINE" '{pemContent: $pemContent}'
        fi
    else
        echo "Warning: puttygen not found, outputting PEM only (install putty-tools for PPK support)" >&2
        jq -n --arg pemContent "$PEM_SINGLE_LINE" '{pemContent: $pemContent}'
    fi
else
    # Output JSON with PEM only
    jq -n --arg pemContent "$PEM_SINGLE_LINE" '{pemContent: $pemContent}'
fi

rm -rf "$TMP_DIR"

#echo "✅ User $USER created on $REMOTE_HOST with public key marker britive-$TRX"
#echo "🔑 Private key above — save it securely!"