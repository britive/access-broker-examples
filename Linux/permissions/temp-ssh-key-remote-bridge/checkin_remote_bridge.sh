#!/bin/sh

# Checkin script for SSH key access via the Britive bridge platform.
# Removes the one-time ed25519 key provisioned during checkout,
# cleans up any sudoers entry created for the session, and
# terminates the bridge session via bridge.sh checkout-delete.
#
# Required environment variables (set by Britive):
#   BRITIVE_USER_EMAIL  - Britive user email (username derived from local part)
#   TRX                 - Britive transaction ID (matches the checkout TRX)
#   BRITIVE_REMOTE_HOST - SSH target host
#
# Optional environment variables:
#   REMOTE_USER         - Privileged SSH account used for provisioning (default: britivebroker)
#   PROVISION_HOST      - Privileged SSH host (default: BRITIVE_REMOTE_HOST)
#   PROVISION_PORT      - SSH port for provisioning (default: 22)
#   PROVISION_KEY       - Path to provisioning private key (default: /home/bridge/.ssh/id_ed25519)
#   BRITIVE_SUDO        - Set to 1 if sudo was granted during checkout (default: 0)
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

require_var BRITIVE_USER_EMAIL
require_var TRX
require_var BRITIVE_REMOTE_HOST

# ==============================
# Remove provisioned key and cleanup on remote host
# ==============================
ssh -i "$PROVISION_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -p "$PROVISION_PORT" \
    "${PROVISION_USER}@${PROVISION_HOST}" \
    sh -s -- "$TARGET_USERNAME" "$PROVISION_SUDO" "$TRANSACTION_ID" <<'REMOTE'
set -eu
TARGET_USER="$1"
SUDO="$2"
TRANSACTION_ID="$3"
MARKER="bridge:${TRANSACTION_ID}"

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

HOME_DIR="$(eval echo "~${TARGET_USER}")"
AUTH_KEYS="${HOME_DIR}/.ssh/authorized_keys"

# --- Remove the injected key (matched by the bridge:<transaction_id> comment) ---
if run_root test -f "$AUTH_KEYS"; then
    run_root grep -vF "$MARKER" "$AUTH_KEYS" | run_root tee "${AUTH_KEYS}.tmp" >/dev/null
    run_root mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    run_root chmod 600 "$AUTH_KEYS"
    run_root chown "${TARGET_USER}:" "$AUTH_KEYS"
    echo "Removed key with marker $MARKER for user $TARGET_USER"
else
    echo "No authorized_keys file found for $TARGET_USER"
fi

# --- Remove sudoers entry if it was created during checkout ---
if [ "$SUDO" = "1" ]; then
    SUDOERS_FILE="/etc/sudoers.d/bridge-${TRANSACTION_ID}"
    if run_root test -f "$SUDOERS_FILE"; then
        run_root rm -f "$SUDOERS_FILE"
        echo "Removed sudoers entry $SUDOERS_FILE"
    fi
fi

# --- Optionally delete the user account ---
#if [ "${DELETE_USER:-0}" = "1" ]; then
#    if id "$TARGET_USER" >/dev/null 2>&1; then
#        run_root userdel -r "$TARGET_USER" || true
#        echo "Deleted user $TARGET_USER and home directory"
#    fi
#fi
REMOTE

# ==============================
# Terminate the bridge session
# ==============================
"${BROKER_API}" checkout-delete "${TRANSACTION_ID}"
