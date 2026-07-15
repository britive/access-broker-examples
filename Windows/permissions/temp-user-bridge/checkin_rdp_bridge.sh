#!/bin/bash
#
# Britive checkin script: Bridge (v2) session teardown + temp Windows user removal
#
# Deletes the Bridge checkout FIRST so the RDP proxy session closes before
# the Windows account is removed, then deprovisions the temp local user
# (group memberships and account) via WinRM or SSH.
#
# Required env vars (set by Britive Resource Type / Profile):
#   BRITIVE_USER_EMAIL - requesting user's email (must match checkout)
#   TRX                - Britive transaction ID (matches the checkout TRX)
#   TARGET_HOST        - Windows RDP target host
#
# Optional env vars (with defaults):
#   LOCAL_GROUP         - comma-separated local groups (default: Remote Desktop Users)
#   PROVISION_TRANSPORT - winrm (default) or ssh
#   PROVISION_HOST      - provisioning host (default: TARGET_HOST)
#   PROVISION_USER      - privileged account (default: Administrator)
#   PROVISION_PASSWORD  - required for winrm transport
#   PROVISION_PORT      - default 5985/5986 (winrm) or 22 (ssh)
#   PROVISION_KEY       - path to SSH provisioning key (default: /home/bridge/.ssh/id_ed25519)
#   PROVISION_KEY_PEM   - inline PEM content of the provisioning key
#   WINRM_NO_SSL        - 1 for HTTP/5985 (default: 1), 0 for HTTPS/5986
#   BROKER_API          - path to broker-bridge-api.sh
#                         (default: /opt/britive-broker/scripts/broker-bridge-api.sh)

set -u

USER_EMAIL="${BRITIVE_USER_EMAIL:-}"
TRANSACTION_ID="${TRX:-}"
TARGET_HOST="${TARGET_HOST:-}"
LOCAL_GROUP="${LOCAL_GROUP:-Remote Desktop Users}"
PROVISION_TRANSPORT="${PROVISION_TRANSPORT:-winrm}"
PROVISION_HOST="${PROVISION_HOST:-${TARGET_HOST}}"
PROVISION_USER="${PROVISION_USER:-Administrator}"
PROVISION_PASSWORD="${PROVISION_PASSWORD:-}"
PROVISION_KEY="${PROVISION_KEY:-/home/bridge/.ssh/id_ed25519}"
PROVISION_KEY_PEM="${PROVISION_KEY_PEM:-}"
WINRM_NO_SSL="${WINRM_NO_SSL:-1}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

if [ "$PROVISION_TRANSPORT" = "winrm" ]; then
    if [ "$WINRM_NO_SSL" = "1" ]; then
        PROVISION_PORT="${PROVISION_PORT:-5985}"
    else
        PROVISION_PORT="${PROVISION_PORT:-5986}"
    fi
else
    PROVISION_PORT="${PROVISION_PORT:-22}"
fi

# --- Validation ---
fail() { echo "error: $1" >&2; exit 1; }

for var in BRITIVE_USER_EMAIL TRX TARGET_HOST; do
    eval "val=\${$var:-}"
    [ -n "$val" ] || fail "required env var missing: $var"
done

command -v python3 >/dev/null 2>&1 || fail "python3 not found"

case "$PROVISION_TRANSPORT" in
    winrm)
        [ -n "$PROVISION_PASSWORD" ] || fail "PROVISION_PASSWORD required for winrm transport"
        python3 -c "import winrm" 2>/dev/null || fail "pywinrm not installed — run: pip install pywinrm"
        ;;
    ssh)
        command -v ssh >/dev/null 2>&1 || fail "ssh not found"
        [ -n "$PROVISION_KEY_PEM" ] || [ -f "$PROVISION_KEY" ] || \
            fail "SSH transport requires PROVISION_KEY_PEM or key file at $PROVISION_KEY"
        ;;
    *) fail "PROVISION_TRANSPORT must be 'winrm' or 'ssh' (got: $PROVISION_TRANSPORT)" ;;
esac

# --- Derive Windows username (must match checkout) ---
USERNAME="$(python3 -c "
import re, sys
name = re.sub(r'[^a-z0-9]', '', sys.argv[1].split('@')[0].lower())
if not name:
    sys.exit('error: cannot derive username from: ' + sys.argv[1])
if name[0].isdigit():
    name = 'brg' + name
print(name[:20])
" "$USER_EMAIL")"

# --- Temp files & cleanup ---
PS_FILE=""
KEY_FILE=""
trap 'rm -f ${PS_FILE:+"$PS_FILE"} ${KEY_FILE:+"$KEY_FILE"}' EXIT INT TERM
umask 077

if [ "$PROVISION_TRANSPORT" = "ssh" ] && [ -n "$PROVISION_KEY_PEM" ]; then
    KEY_FILE="$(mktemp -p /dev/shm 2>/dev/null || mktemp)"
    printf '%s\n' "$PROVISION_KEY_PEM" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    PROVISION_KEY="$KEY_FILE"
fi

rc=0

# --- Terminate the Bridge session first ---
"${BROKER_API}" checkout-delete "${TRANSACTION_ID}" || rc=1
echo "[checkin] Bridge session terminated" >&2

# --- PowerShell deprovision script (best-effort after session revoked) ---
PS_CHECKIN="$(cat <<PS_EOF
\$ProgressPreference = 'SilentlyContinue'
\$username = '${USERNAME}'
\$groups   = '${LOCAL_GROUP}'.Split(',') | ForEach-Object { \$_.Trim() } | Where-Object { \$_ -ne '' }

foreach (\$group in \$groups) {
    try {
        Remove-LocalGroupMember -Group \$group -Member \$username -ErrorAction Stop
        Write-Output ('Removed ' + \$username + ' from ' + \$group)
    } catch {
        Write-Warning ('Could not remove from ' + \$group + ': ' + \$_.Exception.Message)
    }
}

try {
    Remove-LocalUser -Name \$username -ErrorAction Stop
    Write-Output ('Deleted user: ' + \$username)
} catch {
    Write-Warning ('Could not delete user ' + \$username + ': ' + \$_.Exception.Message)
}
PS_EOF
)"

# --- Deprovision user on Windows target ---
echo "[checkin] removing ${USERNAME} from ${PROVISION_HOST} via ${PROVISION_TRANSPORT}" >&2

case "$PROVISION_TRANSPORT" in
    winrm)
        PS_FILE="$(mktemp)"
        printf '%s' "$PS_CHECKIN" > "$PS_FILE"

        WINRM_SCHEME="https"
        [ "$WINRM_NO_SSL" = "1" ] && WINRM_SCHEME="http"

        PROVISION_HOST="$PROVISION_HOST" \
        PROVISION_USER="$PROVISION_USER" \
        PROVISION_PASSWORD="$PROVISION_PASSWORD" \
        PROVISION_PORT="$PROVISION_PORT" \
        WINRM_SCHEME="$WINRM_SCHEME" \
        PS_FILE="$PS_FILE" \
        python3 - <<'PYEOF' || rc=1
import os, sys

try:
    import winrm
except ImportError:
    sys.stderr.write("error: pywinrm not installed\n")
    sys.exit(1)

host     = os.environ['PROVISION_HOST']
user     = os.environ['PROVISION_USER']
password = os.environ['PROVISION_PASSWORD']
port     = int(os.environ.get('PROVISION_PORT', '5986'))
scheme   = os.environ.get('WINRM_SCHEME', 'https')

with open(os.environ['PS_FILE']) as f:
    script = f.read()

try:
    session = winrm.Session(
        target='{}://{}:{}/wsman'.format(scheme, host, port),
        auth=(user, password),
        transport='ntlm',
        server_cert_validation='ignore',
        read_timeout_sec=20,
        operation_timeout_sec=15,
    )
    result = session.run_ps(script)
except Exception as e:
    sys.stderr.write('[checkin] WinRM error: {}\n'.format(e))
    sys.exit(1)

ps_out = result.std_out.decode('utf-8', 'replace').strip()
ps_err = result.std_err.decode('utf-8', 'replace').strip()

if ps_out:
    sys.stderr.write('[checkin] {}\n'.format(ps_out))
if ps_err:
    sys.stderr.write('[checkin] PS stderr: {}\n'.format(ps_err))

if result.status_code != 0:
    sys.stderr.write('[checkin] PS failed (status_code={})\n'.format(result.status_code))
    sys.exit(1)
PYEOF
        ;;
    ssh)
        ENCODED="$(printf '%s' "$PS_CHECKIN" | \
            python3 -c 'import sys, base64; print(base64.b64encode(sys.stdin.read().encode("utf-16-le")).decode())')"
        ssh -i "$PROVISION_KEY" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -o BatchMode=yes \
            -p "$PROVISION_PORT" \
            "${PROVISION_USER}@${PROVISION_HOST}" \
            "powershell.exe -NonInteractive -EncodedCommand ${ENCODED}" >/dev/null || rc=1
        ;;
esac

echo "[checkin] user removed" >&2
exit "$rc"
