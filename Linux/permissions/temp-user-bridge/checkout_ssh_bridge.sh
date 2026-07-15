#!/bin/bash
#
# Britive checkout script: temp Linux user + Bridge (v2) proxied SSH session
#
# Creates a temporary Linux user on the target host with a one-time ed25519
# key (Bridge -> target auth), then registers an SSH checkout with the Bridge
# using the caller's BRIDGE CREDENTIALS (native_auth=bridge_credentials).
#
# Bridge credential (provided by the broker as env vars):
#   BRIDGE_AUTH_PASSWORD - bridge password the user types at the native
#                          password prompt. REQUIRED: the Bridge rejects a
#                          bridge_credentials checkout without it.
#   BRIDGE_AUTH_PUBKEY   - user's SSH PUBLIC key (openssh format). OPTIONAL:
#                          when set, it is added as user_public_key so the user
#                          may authenticate with their own key in addition to
#                          the password.
#
# Identity: the native login username is the user's Britive identity
# (BRITIVE_USER_EMAIL) -- the SAME value as the checkout owner. The Bridge
# matches BOTH the native ssh username (before %) AND the browser SSO identity
# against the checkout's "username" field, so they must be identical. The
# profile "Bridge Username" field is NOT used for matching.
#
# Required env vars (set by Britive Resource Type / Profile):
#   BRITIVE_USER_EMAIL - requesting user's email (temp Linux username derived
#                        from the local part)
#   TRX                - Britive transaction ID
#   TARGET_HOST        - SSH target host
#   BRIDGE_URL         - Bridge web hostname (browser sessions)
#   EXPIRATION         - Checkout duration in seconds
#
# Optional env vars (with defaults):
#   NATIVE_HOST        - hostname native ssh clients connect to, when it
#                        differs from the web host (e.g. web on an ALB,
#                        native listeners on an NLB). Default: BRIDGE_URL host.
#   TARGET_PORT        - SSH port on the target (default: 22)
#   NATIVE_PORT        - Bridge native SSH listener port (default: 2222)
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
BRIDGE_AUTH_PASSWORD="${BRIDGE_AUTH_PASSWORD:-}"
BRIDGE_AUTH_PUBKEY="${BRIDGE_AUTH_PUBKEY:-}"
PROVISION_SUDO="${BRITIVE_SUDO:-0}"
PROVISION_USER="${PROVISION_USER:-britivebroker}"
PROVISION_HOST="${PROVISION_HOST:-${TARGET_HOST}}"
PROVISION_PORT="${PROVISION_PORT:-${TARGET_PORT}}"
PROVISION_KEY="${PROVISION_KEY:-/home/bridge/.ssh/id_ed25519}"
PROVISION_KEY_PEM="${PROVISION_KEY_PEM:-}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

fail() { echo "error: $1" >&2; exit 1; }

for var in BRITIVE_USER_EMAIL TRX TARGET_HOST BRIDGE_URL EXPIRATION BRIDGE_AUTH_PASSWORD; do
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
# native_auth=bridge_credentials always requires bridge_auth_password -- the
# Bridge rejects the checkout without it. When BRIDGE_AUTH_PUBKEY is set it is
# added as user_public_key so the user may authenticate with their own key in
# addition to the password.
EXPIRES_AT="$(($(date +%s) + EXPIRATION))"
PRIVATE_KEY_JSON="$(jq -Rs . < "$KEYDIR/key")"

if [ -n "$BRIDGE_AUTH_PUBKEY" ]; then
  AUTH_METHOD="pubkey"
  AUTH_FIELDS="$(jq -n --arg p "$BRIDGE_AUTH_PASSWORD" --arg k "$BRIDGE_AUTH_PUBKEY" \
    '{native_auth:"bridge_credentials", bridge_auth_password:$p, user_public_key:$k}')"
else
  AUTH_METHOD="password"
  AUTH_FIELDS="$(jq -n --arg p "$BRIDGE_AUTH_PASSWORD" \
    '{native_auth:"bridge_credentials", bridge_auth_password:$p}')"
fi

jq -n \
  --arg transaction_id "$TRANSACTION_ID" \
  --arg username "$USER_EMAIL" \
  --arg target_host "$TARGET_HOST" \
  --argjson target_port "$TARGET_PORT" \
  --arg target_username "$TARGET_USERNAME" \
  --argjson private_key "$PRIVATE_KEY_JSON" \
  --argjson expires_at "$EXPIRES_AT" \
  --argjson auth "$AUTH_FIELDS" \
  '{transaction_id: $transaction_id,
    protocol: "ssh",
    username: $username,
    target_host: $target_host,
    target_port: $target_port,
    target_username: $target_username,
    private_key: $private_key,
    record_session: true,
    expires_at: $expires_at} + $auth' > "$PAYLOAD_FILE"
# NOTE: "username" is the checkout OWNER — the Britive/SSO identity the Bridge
# matches against for BOTH browser sessions and the native ssh login. It and the
# native login username (bridge_username) must be the same value (USER_EMAIL).

if ! "${BROKER_API}" checkout-create --file "$PAYLOAD_FILE" >/dev/null; then
  rollback
  fail "Bridge checkout registration failed"
fi

echo "[checkout] Bridge session registered (auth: ${AUTH_METHOD})" >&2

# --- Output connection details ---
# BRIDGE_URL is the web host (browser sessions); NATIVE_HOST is what native
# ssh clients connect to — defaults to the web host for single-endpoint
# deployments, override when web (ALB) and native (NLB) endpoints differ.
BRIDGE_HOST="${BRIDGE_URL#https://}"
BRIDGE_HOST="${BRIDGE_HOST#http://}"
BRIDGE_HOST="${BRIDGE_HOST%%[:/]*}"
NATIVE_HOST="${NATIVE_HOST:-${BRIDGE_HOST}}"
NATIVE_USER="${USER_EMAIL}%${TARGET_HOST}"
# Use -l for the username: it contains '@' (email) and '%' (target separator),
# so embedding it as user@host would be ambiguous. -l passes it verbatim.
COMMAND="ssh -p ${NATIVE_PORT} -l '${NATIVE_USER}' ${NATIVE_HOST}"
BROWSER_SESSION="https://${BRIDGE_HOST}/ssh/#transaction_id=${TRANSACTION_ID}"

jq -n \
  --arg BRIDGE_URL "$BRIDGE_HOST" \
  --arg native_host "$NATIVE_HOST" \
  --arg command "$COMMAND" \
  --arg auth_method "$AUTH_METHOD" \
  --arg bridge_username "$NATIVE_USER" \
  --arg bridge_port "$NATIVE_PORT" \
  --arg target_username "$TARGET_USERNAME" \
  --arg browser_session "$BROWSER_SESSION" \
  '{BRIDGE_URL: $BRIDGE_URL, native_host: $native_host, command: $command,
    auth_method: $auth_method, bridge_username: $bridge_username,
    bridge_port: $bridge_port, target_username: $target_username,
    browser_session: $browser_session}'
