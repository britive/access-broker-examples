#!/bin/bash
#
# Britive checkout script: temp Linux user + Bridge (v2) proxied SSH session
#
# Creates a temporary Linux user on the target host with a one-time ed25519
# key (Bridge -> target auth), then registers an SSH checkout with the Bridge.
# The user connects with their local ssh client through the Bridge's native
# SSH listener using a per-checkout Bridge password, or through the browser
# terminal. The one-time private key never leaves the broker/Bridge.
#
# Required env vars (set by Britive Resource Type / Profile):
#   BRITIVE_USER_EMAIL - requesting user's email (username derived from local part)
#   TRX                - Britive transaction ID
#   TARGET_HOST        - SSH target host
#   BRIDGE_URL         - Public Bridge base URL (e.g. https://bridge.example.com)
#   EXPIRATION         - Checkout duration in seconds
#
# Optional env vars (with defaults):
#   TARGET_PORT        - SSH port on the target (default: 22)
#   NATIVE_PORT        - Bridge native SSH listener port (default: 2222)
#   NATIVE_AUTH        - bridge_credentials (default) or ldap
#   USER_PUBLIC_KEY    - user's own SSH public key; if set, key auth to the
#                        Bridge is enabled in addition to the Bridge password
#   BRITIVE_SUDO       - 1 to grant passwordless sudo to the temp user (default: 0)
#   PROVISION_USER     - privileged SSH account for provisioning (default: britivebroker)
#   PROVISION_HOST     - provisioning host (default: TARGET_HOST)
#   PROVISION_PORT     - SSH port for provisioning (default: TARGET_PORT)
#   PROVISION_KEY      - path to provisioning private key (default: /home/bridge/.ssh/id_ed25519)
#   PROVISION_KEY_PEM  - inline PEM content of the provisioning key (preferred over PROVISION_KEY)
#   BROKER_API         - path to broker-bridge-api.sh
#                        (default: /opt/britive-broker/scripts/broker-bridge-api.sh)

set -u

USER_EMAIL="${BRITIVE_USER_EMAIL:-}"
TARGET_USERNAME="${USER_EMAIL%%@*}"
TARGET_USERNAME="${TARGET_USERNAME//[^a-zA-Z0-9]/}"

TRANSACTION_ID="${TRX:-}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_PORT="${TARGET_PORT:-22}"
NATIVE_PORT="${NATIVE_PORT:-2222}"
NATIVE_AUTH="${NATIVE_AUTH:-bridge_credentials}"
USER_PUBLIC_KEY="${USER_PUBLIC_KEY:-}"
PROVISION_SUDO="${BRITIVE_SUDO:-0}"
PROVISION_USER="${PROVISION_USER:-britivebroker}"
PROVISION_HOST="${PROVISION_HOST:-${TARGET_HOST}}"
PROVISION_PORT="${PROVISION_PORT:-${TARGET_PORT}}"
PROVISION_KEY="${PROVISION_KEY:-/home/bridge/.ssh/id_ed25519}"
PROVISION_KEY_PEM="${PROVISION_KEY_PEM:-}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

fail() { echo "error: $1" >&2; exit 1; }

for var in BRITIVE_USER_EMAIL TRX TARGET_HOST BRIDGE_URL EXPIRATION; do
  eval "val=\${$var:-}"
  [ -n "$val" ] || fail "required env var missing: $var"
done

for cmd in ssh ssh-keygen base64 jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

[ -n "$PROVISION_KEY_PEM" ] || [ -f "$PROVISION_KEY" ] || \
  fail "provisioning requires PROVISION_KEY_PEM or key file at $PROVISION_KEY"

# --- Temp files & cleanup ---
KEYDIR="$(mktemp -d)"
PAYLOAD_FILE="$(mktemp)"
PROV_KEY_FILE=""
trap 'rm -f "$PAYLOAD_FILE" ${PROV_KEY_FILE:+"$PROV_KEY_FILE"}; rm -rf "$KEYDIR"' EXIT INT TERM
umask 077

if [ -n "$PROVISION_KEY_PEM" ]; then
  PROV_KEY_FILE="$(mktemp -p /dev/shm 2>/dev/null || mktemp)"
  printf '%s\n' "$PROVISION_KEY_PEM" > "$PROV_KEY_FILE"
  chmod 600 "$PROV_KEY_FILE"
  PROVISION_KEY="$PROV_KEY_FILE"
fi

# --- One-time ed25519 keypair (Bridge -> target auth) ---
ssh-keygen -t ed25519 -f "$KEYDIR/key" -N "" -C "bridge:${TRANSACTION_ID}" >/dev/null 2>&1
PUBKEY_B64="$(base64 < "$KEYDIR/key.pub" | tr -d '\n')"

run_provision() {
  ssh -i "$PROVISION_KEY" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      -p "$PROVISION_PORT" \
      "${PROVISION_USER}@${PROVISION_HOST}" \
      "$@"
}

# --- Provision temp user and key on the target ---
echo "[checkout] provisioning ${TARGET_USERNAME} on ${PROVISION_HOST}" >&2

run_provision sh -s -- "$TARGET_USERNAME" "$PUBKEY_B64" "$PROVISION_SUDO" "$TRANSACTION_ID" <<'REMOTE'
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

echo "[checkout] user provisioned" >&2

# Remove the injected key again if Bridge registration fails
rollback() {
  run_provision sh -s -- "$TARGET_USERNAME" "$TRANSACTION_ID" <<'REMOTE' >/dev/null 2>&1
set -eu
TARGET_USER="$1"
MARKER="bridge:$2"
run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@";
    else sudo -n "$@"; fi
}
HOME_DIR="$(eval echo "~${TARGET_USER}")"
AUTH_KEYS="${HOME_DIR}/.ssh/authorized_keys"
if run_root test -f "$AUTH_KEYS"; then
    run_root cat "$AUTH_KEYS" | grep -vF "$MARKER" > /tmp/ak_clean.tmp || true
    run_root cp /tmp/ak_clean.tmp "$AUTH_KEYS"
    rm -f /tmp/ak_clean.tmp
fi
run_root rm -f "/etc/sudoers.d/bridge-$2"
REMOTE
}

# --- Register the Bridge checkout ---
TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
EXPIRES_AT="$(($(date +%s) + EXPIRATION))"
PRIVATE_KEY_JSON="$(jq -Rs . < "$KEYDIR/key")"

# bridge_credentials: user authenticates to the Bridge proxy with a
# per-checkout password generated here. ldap: user authenticates with
# their own directory password; no password is generated.
if [ "$NATIVE_AUTH" = "bridge_credentials" ]; then
  BRIDGE_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
  AUTH_FIELDS="\"native_auth\": \"bridge_credentials\",
  \"bridge_auth_password\": \"${BRIDGE_PASSWORD}\","
else
  BRIDGE_PASSWORD=""
  AUTH_FIELDS="\"native_auth\": \"${NATIVE_AUTH}\","
fi

USER_PUBKEY_FIELD=""
if [ -n "$USER_PUBLIC_KEY" ]; then
  USER_PUBKEY_FIELD="\"user_public_key\": $(jq -Rn --arg k "$USER_PUBLIC_KEY" '$k'),"
fi

cat > "$PAYLOAD_FILE" <<EOF
{
  "transaction_id": "${TRANSACTION_ID}",
  "protocol": "ssh",
  "username": "${USER_EMAIL}",
  "target_host": "${TARGET_HOST}",
  "target_port": ${TARGET_PORT},
  "target_username": "${TARGET_USERNAME}",
  "private_key": ${PRIVATE_KEY_JSON},
  ${USER_PUBKEY_FIELD}
  ${AUTH_FIELDS}
  "record_session": true,
  "expires_at": ${EXPIRES_AT},
  "token": "${TOKEN}"
}
EOF

if ! "${BROKER_API}" checkout-create --file "$PAYLOAD_FILE" >/dev/null; then
  rollback
  fail "Bridge checkout registration failed"
fi

echo "[checkout] Bridge session registered" >&2

# --- Output connection details ---
# Native clients connect to the Bridge host with username <bridge-user>%<target-host>
BRIDGE_HOST="${BRIDGE_URL#https://}"
BRIDGE_HOST="${BRIDGE_HOST#http://}"
BRIDGE_HOST="${BRIDGE_HOST%%[:/]*}"
NATIVE_USER="${USER_EMAIL}%${TARGET_HOST}"
SSH_CMD="ssh -p ${NATIVE_PORT} '${NATIVE_USER}'@${BRIDGE_HOST}"
URL="${BRIDGE_URL}/connect?transaction_id=${TRANSACTION_ID}"

jq -n \
  --arg token "$TOKEN" \
  --arg url "$URL" \
  --arg ssh_command "$SSH_CMD" \
  --arg bridge_username "$NATIVE_USER" \
  --arg bridge_password "$BRIDGE_PASSWORD" \
  --arg bridge_host "$BRIDGE_HOST" \
  --arg bridge_port "$NATIVE_PORT" \
  --arg target_username "$TARGET_USERNAME" \
  '{token: $token, url: $url, ssh_command: $ssh_command,
    bridge_username: $bridge_username, bridge_password: $bridge_password,
    bridge_host: $bridge_host, bridge_port: $bridge_port,
    target_username: $target_username}'
