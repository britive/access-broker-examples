#!/bin/bash
#
# Britive checkin script: Bridge (v2) session teardown + temp Linux user cleanup
#
# Deletes the Bridge checkout FIRST (revokes the proxy credential and
# terminates any active session), then removes the one-time key and sudoers
# entry provisioned during checkout.
#
# Required env vars (set by Britive Resource Type / Profile):
#   BRITIVE_USER_EMAIL - requesting user's email (must match checkout)
#   TRX                - Britive transaction ID (matches the checkout TRX)
#   TARGET_HOST        - SSH target host
#
# Optional env vars (with defaults):
#   TARGET_PORT        - SSH port on the target (default: 22)
#   BRITIVE_SUDO       - 1 if sudo was granted during checkout (default: 0)
#   PROVISION_USER     - privileged SSH account for provisioning (default: britivebroker)
#   PROVISION_HOST     - provisioning host (default: TARGET_HOST)
#   PROVISION_PORT     - SSH port for provisioning (default: TARGET_PORT)
#   PROVISION_KEY      - path to provisioning private key (default: /home/bridge/.ssh/id_ed25519)
#   PROVISION_KEY_PEM  - inline PEM content of the provisioning key (preferred over PROVISION_KEY)
#   DELETE_USER        - 1 to also delete the temp user account (default: 0)
#   BROKER_API         - path to broker-bridge-api.sh
#                        (default: /opt/britive-broker/scripts/broker-bridge-api.sh)

set -u

USER_EMAIL="${BRITIVE_USER_EMAIL:-}"
TARGET_USERNAME="${USER_EMAIL%%@*}"
TARGET_USERNAME="${TARGET_USERNAME//[^a-zA-Z0-9]/}"

TRANSACTION_ID="${TRX:-}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_PORT="${TARGET_PORT:-22}"
PROVISION_SUDO="${BRITIVE_SUDO:-0}"
PROVISION_USER="${PROVISION_USER:-britivebroker}"
PROVISION_HOST="${PROVISION_HOST:-${TARGET_HOST}}"
PROVISION_PORT="${PROVISION_PORT:-${TARGET_PORT}}"
PROVISION_KEY="${PROVISION_KEY:-/home/bridge/.ssh/id_ed25519}"
PROVISION_KEY_PEM="${PROVISION_KEY_PEM:-}"
DELETE_USER="${DELETE_USER:-0}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

fail() { echo "error: $1" >&2; exit 1; }

for var in BRITIVE_USER_EMAIL TRX TARGET_HOST; do
  eval "val=\${$var:-}"
  [ -n "$val" ] || fail "required env var missing: $var"
done

command -v ssh >/dev/null 2>&1 || fail "required command not found: ssh"

[ -n "$PROVISION_KEY_PEM" ] || [ -f "$PROVISION_KEY" ] || \
  fail "provisioning requires PROVISION_KEY_PEM or key file at $PROVISION_KEY"

PROV_KEY_FILE=""
trap 'rm -f ${PROV_KEY_FILE:+"$PROV_KEY_FILE"}' EXIT INT TERM
umask 077

if [ -n "$PROVISION_KEY_PEM" ]; then
  PROV_KEY_FILE="$(mktemp -p /dev/shm 2>/dev/null || mktemp)"
  printf '%s\n' "$PROVISION_KEY_PEM" > "$PROV_KEY_FILE"
  chmod 600 "$PROV_KEY_FILE"
  PROVISION_KEY="$PROV_KEY_FILE"
fi

rc=0

# --- Terminate the Bridge session first ---
"${BROKER_API}" checkout-delete "${TRANSACTION_ID}" || rc=1
echo "[checkin] Bridge session terminated" >&2

# --- Remove provisioned key, sudoers entry, and optionally the user ---
echo "[checkin] cleaning up ${TARGET_USERNAME} on ${PROVISION_HOST}" >&2

ssh -i "$PROVISION_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -p "$PROVISION_PORT" \
    "${PROVISION_USER}@${PROVISION_HOST}" \
    sh -s -- "$TARGET_USERNAME" "$TRANSACTION_ID" "$DELETE_USER" <<'REMOTE' || rc=1
set -eu
TARGET_USER="$1"
TRANSACTION_ID="$2"
DELETE_USER="$3"
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

# Remove the injected key (matched by the bridge:<transaction_id> comment)
if run_root test -f "$AUTH_KEYS"; then
    BEFORE=$(run_root cat "$AUTH_KEYS" | wc -l)
    run_root cat "$AUTH_KEYS" | grep -vF "$MARKER" > /tmp/ak_clean.tmp || true
    run_root cp /tmp/ak_clean.tmp "$AUTH_KEYS"
    rm -f /tmp/ak_clean.tmp
    run_root chmod 600 "$AUTH_KEYS"
    run_root chown "${TARGET_USER}:" "$AUTH_KEYS"
    AFTER=$(run_root cat "$AUTH_KEYS" | wc -l)
    echo "authorized_keys: removed $((BEFORE - AFTER)) key(s) matching '$MARKER' for $TARGET_USER"
else
    echo "No authorized_keys file found for $TARGET_USER — skipping"
fi

# Always remove the sudoers entry for this transaction
SUDOERS_FILE="/etc/sudoers.d/bridge-${TRANSACTION_ID}"
if run_root test -f "$SUDOERS_FILE"; then
    run_root rm -f "$SUDOERS_FILE"
    echo "Removed sudoers entry $SUDOERS_FILE"
fi

# Optionally delete the temp user account
if [ "$DELETE_USER" = "1" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    run_root userdel -r "$TARGET_USER" || true
    echo "Deleted user $TARGET_USER and home directory"
fi
REMOTE

echo "[checkin] target cleanup complete" >&2
exit "$rc"
