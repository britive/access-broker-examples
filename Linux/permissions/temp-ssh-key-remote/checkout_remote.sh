#!/bin/sh
set -eu

# ==============================
# Configurable Variables
# ==============================
USER_EMAIL="${BRITIVE_USER_EMAIL:-}"
USERNAME="${USER_EMAIL%%@*}"
USERNAME="$(printf '%s' "$USERNAME" | tr -cd 'a-zA-Z0-9')"

TRX="${TRX:-}"
TARGET_USER="${USERNAME}"
SUDO_FLAG="${BRITIVE_SUDO:-0}"
REMOTE_USER="${REMOTE_USER:-britivebroker}"
REMOTE_HOST="${BRITIVE_REMOTE_HOST:-${HOST:-}}"
REMOTE_KEY="${REMOTE_KEY:-/home/britivebroker/.ssh/MYKEY.pem}"

# ===== Fail-fast checks =====
[ -z "$REMOTE_HOST" ]  && { echo "ERROR: REMOTE_HOST empty — set BRITIVE_REMOTE_HOST" >&2; exit 1; }
[ -z "$USER_EMAIL" ]   && { echo "ERROR: BRITIVE_USER_EMAIL empty" >&2; exit 1; }
[ -z "$TRX" ]          && { echo "ERROR: TRX empty" >&2; exit 1; }
[ ! -f "$REMOTE_KEY" ] && { echo "ERROR: SSH key not found at $REMOTE_KEY" >&2; exit 1; }

# ======================================
# Generate keypair in secure temp dir
# ======================================
umask 077
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

SSH_KEY_LOCAL="$TMP_DIR/britive_key"
SSH_KEY_PUB="$TMP_DIR/britive_key.pub"

ssh-keygen -q -N '' -t ed25519 -C "$USER_EMAIL" -f "$SSH_KEY_LOCAL"

PUBKEY_B64="$(base64 < "$SSH_KEY_PUB" | tr -d '\n')"

# ==============================
# Provision user and key on remote host
# ==============================
ssh \
    -i "$REMOTE_KEY" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$REMOTE_USER@$REMOTE_HOST" \
    sh -s -- "$TARGET_USER" "$PUBKEY_B64" "$SUDO_FLAG" "$TRX" <<'REMOTE'
set -eu
TARGET_USER="$1"
PUBKEY_B64="$2"
SUDO_FLAG="$3"
TRX="$4"
PUBKEY="$(printf '%s' "$PUBKEY_B64" | base64 -d)"

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
    else
        echo "error: provisioning user requires root or passwordless sudo" >&2
        exit 1
    fi
}

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        run_root useradd -m -s /bin/bash "$TARGET_USER"
    else
        run_root adduser -D -s /bin/bash "$TARGET_USER"
    fi
fi

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -z "$HOME_DIR" ] && { echo "error: user $TARGET_USER missing from passwd" >&2; exit 1; }

run_root mkdir -p "${HOME_DIR}/.ssh"
run_root chmod 700 "${HOME_DIR}/.ssh"

AUTH_KEYS="${HOME_DIR}/.ssh/authorized_keys"
if ! run_root grep -qF "# britive-${TRX}" "$AUTH_KEYS" 2>/dev/null; then
    printf '%s # britive-%s\n' "$PUBKEY" "$TRX" | run_root tee -a "$AUTH_KEYS" >/dev/null
fi

run_root chmod 600 "$AUTH_KEYS"
run_root chown -R "${TARGET_USER}:" "${HOME_DIR}/.ssh"
command -v restorecon >/dev/null 2>&1 && run_root restorecon -R "${HOME_DIR}/.ssh" >/dev/null 2>&1 || true

if [ "$SUDO_FLAG" = "1" ]; then
    SUDOERS_FILE="/etc/sudoers.d/britive-${TRX}"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" | run_root tee "$SUDOERS_FILE" >/dev/null
    run_root chmod 440 "$SUDOERS_FILE"
fi
REMOTE

# ==============================
# Output private key (PEM) to stdout
# ==============================
cat "$SSH_KEY_LOCAL"
