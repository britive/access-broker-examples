#!/bin/sh

# Checkout script for SSH key access via the Britive bridge platform.
# Provisions the target host with a one-time ed25519 key, then registers
# a proxied SSH session with the bridge and returns a connection URL.
#
# Required environment variables (set by Britive):
#   BRITIVE_USER_EMAIL  - Britive user email (username derived from local part)
#   TRX                 - Britive transaction ID
#   BRITIVE_REMOTE_HOST - SSH target host
#   BRIDGE_URL          - Public bridge base URL (e.g. https://bridge.example.com)
#   EXPIRATION          - Checkout duration in seconds
#
# Optional environment variables:
#   REMOTE_USER         - Privileged SSH account used for provisioning (default: britivebroker)
#   PROVISION_HOST      - Privileged SSH host (default: BRITIVE_REMOTE_HOST)
#   PROVISION_PORT      - SSH port for provisioning (default: 22)
#   PROVISION_KEY       - Path to provisioning private key (default: /home/bridge/.ssh/id_ed25519)
#   BRITIVE_SUDO        - Set to 1 to grant passwordless sudo to the target user (default: 0)
#   BROKER_API          - Path to bridge.sh (default: /opt/britive-broker/scripts/bridge.sh)

set -eu

# ==============================
# Configurable Variables
# ==============================
USER_EMAIL="${BRITIVE_USER_EMAIL:-}"
USERNAME="${USER_EMAIL%%@*}"
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"

TRANSACTION_ID="${TRX:-}"
TARGET_HOST="${BRITIVE_REMOTE_HOST:-}"
TARGET_USERNAME="${USERNAME}"
PROVISION_HOST="${PROVISION_HOST:-${TARGET_HOST}}"
PROVISION_PORT="${PROVISION_PORT:-22}"
PROVISION_USER="${REMOTE_USER:-britivebroker}"
PROVISION_KEY="${PROVISION_KEY:-/home/bridge/.ssh/id_ed25519}"
PROVISION_SUDO="${BRITIVE_SUDO:-0}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/bridge.sh}"

# ==============================
# Validation helpers
# ==============================
require_var() {
    var_name="$1"
    eval "var_value=\${$1:-}"
    if [ -z "$var_value" ]; then
        echo "error: required env var missing: $var_name" >&2
        exit 1
    fi
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required command not found: $1" >&2
        exit 1
    fi
}

require_var BRITIVE_USER_EMAIL
require_var TRX
require_var BRITIVE_REMOTE_HOST
require_var BRIDGE_URL
require_var EXPIRATION

require_cmd ssh
require_cmd ssh-keygen
require_cmd base64
require_cmd python3

# ==============================
# Temp file setup & cleanup trap
# ==============================
KEYDIR="$(mktemp -d)"
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"; rm -rf "$KEYDIR"' EXIT INT TERM
umask 077

# ==============================
# Generate one-time ed25519 keypair
# ==============================
ssh-keygen -t ed25519 -f "$KEYDIR/key" -N "" -C "bridge:${TRANSACTION_ID}" >/dev/null 2>&1

PUBKEY_B64="$(cat "$KEYDIR/key.pub" | base64 | tr -d '\n')"

# ==============================
# Provision user and key on remote host
# ==============================
ssh -i "$PROVISION_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -p "$PROVISION_PORT" \
    "${PROVISION_USER}@${PROVISION_HOST}" \
    sh -s -- "$TARGET_USERNAME" "$PUBKEY_B64" "$PROVISION_SUDO" "$TRANSACTION_ID" <<'REMOTE'
set -eu
TARGET_USER="$1"
PUBKEY_B64="$2"
SUDO="$3"
TRANSACTION_ID="$4"
PUBKEY="$(printf '%s' "$PUBKEY_B64" | base64 -d)"

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
    else
        echo "error: provisioning user requires root or passwordless sudo" >&2
        exit 1
    fi
}

# Create user if missing
if ! id "$TARGET_USER" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        run_root useradd -m -s /bin/bash "$TARGET_USER"
    elif adduser --help 2>&1 | grep -q -- '--disabled-password'; then
        run_root adduser --disabled-password --gecos "" "$TARGET_USER"
    else
        run_root adduser -D -s /bin/bash "$TARGET_USER"
    fi
fi

HOME_DIR="$(eval echo "~${TARGET_USER}")"
run_root mkdir -p "${HOME_DIR}/.ssh"
run_root chmod 700 "${HOME_DIR}/.ssh"

AUTH_KEYS="${HOME_DIR}/.ssh/authorized_keys"
if ! run_root grep -qF "$PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
    printf '%s\n' "$PUBKEY" | run_root tee -a "$AUTH_KEYS" >/dev/null
fi

run_root chmod 600 "$AUTH_KEYS"
run_root chown -R "${TARGET_USER}:" "${HOME_DIR}/.ssh"

if [ "$SUDO" = "1" ]; then
    SUDOERS_FILE="/etc/sudoers.d/bridge-${TRANSACTION_ID}"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" | run_root tee "$SUDOERS_FILE" >/dev/null
    run_root chmod 440 "$SUDOERS_FILE"
fi
REMOTE

# ==============================
# Build bridge JSON payload
# ==============================
PRIVATE_KEY_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < "$KEYDIR/key")"
TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
NOW_EPOCH="$(date +%s)"
EXPIRES_AT="$((NOW_EPOCH + EXPIRATION))"

cat > "$PAYLOAD_FILE" <<EOF
{
  "transaction_id": "${TRANSACTION_ID}",
  "protocol": "ssh",
  "username": "${USER_EMAIL}",
  "target_host": "${TARGET_HOST}",
  "target_port": 22,
  "target_username": "${TARGET_USERNAME}",
  "private_key": ${PRIVATE_KEY_JSON},
  "expires_at": ${EXPIRES_AT},
  "token": "${TOKEN}"
}
EOF

# ==============================
# Register session with bridge
# ==============================
"${BROKER_API}" checkout-create --file "$PAYLOAD_FILE" >/dev/null

# ==============================
# Output connection token and URL
# ==============================
URL="${BRIDGE_URL}/ssh/#token=${TOKEN}&transaction_id=${TRANSACTION_ID}"
printf '{"token": "%s", "url": "%s"}\n' "${TOKEN}" "${URL}"
