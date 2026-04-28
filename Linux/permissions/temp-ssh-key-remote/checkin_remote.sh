#!/bin/sh
set -eu

# ==============================
# Variables
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

# ==============================
# Remove key and sudoers entry on remote host
# ==============================
ssh \
    -i "$REMOTE_KEY" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$REMOTE_USER@$REMOTE_HOST" \
    sh -s -- "$TARGET_USER" "$TRX" "$SUDO_FLAG" <<'REMOTE'
set -eu
TARGET_USER="$1"
TRX="$2"
SUDO_FLAG="$3"
MARKER="# britive-${TRX}"

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
    echo "warning: user ${TARGET_USER} does not exist on host" >&2
else
    HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    AUTHORIZED_KEYS="${HOME_DIR}/.ssh/authorized_keys"

    if [ -n "$HOME_DIR" ] && run_root test -f "$AUTHORIZED_KEYS"; then
        if run_root grep -qF "$MARKER" "$AUTHORIZED_KEYS"; then
            run_root grep -vF "$MARKER" "$AUTHORIZED_KEYS" | run_root tee "${AUTHORIZED_KEYS}.tmp" >/dev/null || true
            run_root mv "${AUTHORIZED_KEYS}.tmp" "$AUTHORIZED_KEYS"
            run_root chmod 600 "$AUTHORIZED_KEYS"
            run_root chown "${TARGET_USER}:" "$AUTHORIZED_KEYS"
            command -v restorecon >/dev/null 2>&1 && run_root restorecon "$AUTHORIZED_KEYS" >/dev/null 2>&1 || true
        else
            echo "info: marker ${MARKER} not found in authorized_keys (already removed?)" >&2
        fi
    else
        echo "warning: no authorized_keys found for ${TARGET_USER}" >&2
    fi
fi

if [ "$SUDO_FLAG" = "1" ]; then
    SUDOERS_FILE="/etc/sudoers.d/britive-${TRX}"
    if run_root test -f "$SUDOERS_FILE"; then
        run_root rm -f "$SUDOERS_FILE"
    fi
fi
REMOTE
