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
REMOTE_KEY="/ssh/key-linux.pem"  # <-- Path to your AWS PEM file

SECRET_KEY=$(aws --region us-west-2 secretsmanager get-secret-value --secret-id ${json_secret_key} --query "SecretString" | jq -r | jq -r .key)

TRX=${TRX:-"britive-trx-id"}  # Transaction ID marker

# ===== Fail-fast checks =====
[[ -z "$REMOTE_HOST" ]] && { echo "ERROR: REMOTE_HOST is empty"; exit 1; }
[[ ! -f "$REMOTE_KEY" ]] && { echo "ERROR: SSH key not found at $REMOTE_KEY"; exit 1; }
if [[ -z "${SECRET_KEY:-}" ]]; then
  echo "ERROR: SECRET_KEY is not set"; exit 1
fi
if ! [[ "$SECRET_KEY" =~ ^[0-9A-Fa-f]{32}$ ]]; then
  echo "ERROR: SECRET_KEY must be 32 hex chars (16 bytes)"; exit 1
fi


# ==============================
# Generate SSH keypair in temp location
# ==============================
TMP_DIR=$(mktemp -d)
SSH_KEY_LOCAL="$TMP_DIR/britive-id_rsa"
SSH_KEY_PUB="$TMP_DIR/britive-id_rsa.pub"

ssh-keygen -q -N '' -t rsa -C "$USER_EMAIL" -f "$SSH_KEY_LOCAL"

# ==============================
# Create user and setup on remote server
# ==============================
ssh -i "$REMOTE_KEY" -o IdentitiesOnly=yes "$REMOTE_USER@$REMOTE_HOST" bash -s <<EOF
set -e

TARGET_USER="$TARGET_USER"
TARGET_GROUP="$TARGET_GROUP"
SUDO_FLAG="$SUDO_FLAG"
HOME_ROOT="$HOME_ROOT"

SSH_PATH=/"\$HOME_ROOT"/"\$TARGET_USER"/.ssh

# Create user if missing
if ! id -u "\$TARGET_USER" >/dev/null 2>&1; then
  sudo useradd -m "\$TARGET_USER"
fi

# Ensure group exists (some dists won't auto-create with useradd)
if ! getent group "\$TARGET_GROUP" >/dev/null 2>&1; then
  sudo groupadd "\$TARGET_GROUP" || true
fi
sudo usermod -g "\$TARGET_GROUP" "\$TARGET_USER" >/dev/null 2>&1 || true

# Ensure .ssh exists with correct perms
if [ ! -d "\$SSH_PATH" ]; then
  sudo mkdir -p "\$SSH_PATH"
  sudo chown "\$TARGET_USER:\$TARGET_GROUP" "\$SSH_PATH"
  sudo chmod 700 "\$SSH_PATH"
fi

# Optional sudoers
if [ "\$SUDO_FLAG" != "0" ]; then
  echo "\${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/\${TARGET_USER}" >/dev/null
  sudo chmod 440 "/etc/sudoers.d/\${TARGET_USER}"
fi

EOF


# ==============================
# Append public key with TRX marker and push it to remote
# ==============================
PUB_KEY_WITH_MARKER="$(cat "$SSH_KEY_PUB") # britive-$TRX"
echo "$PUB_KEY_WITH_MARKER" > "$TMP_DIR/britive-id_rsa_marker.pub"

scp -i "$REMOTE_KEY" -o IdentitiesOnly=yes "$TMP_DIR/britive-id_rsa_marker.pub" "$REMOTE_USER@$REMOTE_HOST:/tmp/britive-id_rsa_marker.pub"

# ===== Append to authorized_keys (re-ensure .ssh exists just in case) =====
ssh -i "$REMOTE_KEY" -o IdentitiesOnly=yes "$REMOTE_USER@$REMOTE_HOST" bash -s <<EOF
set -e

TARGET_USER="$TARGET_USER"
HOME_ROOT="$HOME_ROOT"
SSH_PATH=/"\$HOME_ROOT"/"\$TARGET_USER"/.ssh

if [ ! -d "\$SSH_PATH" ]; then
  sudo mkdir -p "\$SSH_PATH"
  sudo chown "\$TARGET_USER:\$TARGET_USER" "\$SSH_PATH"
  sudo chmod 700 "\$SSH_PATH"
fi

sudo touch "\$SSH_PATH/authorized_keys"
sudo bash -c "cat /tmp/britive-id_rsa_marker.pub >> '\$SSH_PATH/authorized_keys'"
sudo rm -f /tmp/britive-id_rsa_marker.pub
sudo chmod 600 "\$SSH_PATH/authorized_keys"
sudo chown "\$TARGET_USER:\$TARGET_USER" "\$SSH_PATH/authorized_keys"
EOF

SSH_KEY=$(cat "$SSH_KEY_LOCAL")

JSON_STRING='{
  "username": "'${USER_EMAIL}'",
  "expires": "'$(date -d "+${expiration} seconds" +%s)'000",
  "connections": {
    "'${connection_name}'":
      {
        "protocol": "ssh",
        "parameters": {
          "hostname": "'${REMOTE_HOST}'",
          "port": "22",
          "username": "'${TARGET_USER}'",
          "private-key": "'${SSH_KEY//$'\n'/\\n}'",
          "recording-path": "'${recording_path:-/home/guacd/recordings}'",
          "recording-name": "${GUAC_DATE}-${GUAC_TIME}-'${USER_EMAIL}'-'${USERNAME}'-'${connection_name}'"
        }
      }
  }
}'

JSON=$(echo -n $JSON_STRING | jq -r tostring)


sign() {
    echo -n "${JSON}" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"${SECRET_KEY}" -binary
    echo -n "${JSON}"
}

encrypt() {
    openssl enc -aes-128-cbc -K "${SECRET_KEY}" -iv "00000000000000000000000000000000" -nosalt -a
}

TOKEN=$(sign | encrypt | tr -d "\n\r" | jq -Rr @uri)

echo -n '{"token": "'${TOKEN}'", "url": "'${url}'"}'