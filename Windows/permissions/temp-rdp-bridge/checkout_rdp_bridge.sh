#!/bin/sh
# Checkout: create temp Windows user, register Bridge RDP session, return URL.
#
# Required env vars: BRITIVE_USER_EMAIL, TRX, TARGET_HOST, BRIDGE_URL, EXPIRATION
# Optional: TARGET_PORT(3389), BRITIVE_FIRST_NAME, BRITIVE_LAST_NAME,
#   PROVISION_HOST, PROVISION_TRANSPORT(winrm|ssh),
#   PROVISION_USER(Administrator), PROVISION_PASSWORD, PROVISION_PORT,
#   PROVISION_KEY(/home/bridge/.ssh/id_ed25519), PROVISION_KEY_PEM,
#   WINRM_NO_SSL(1), LOCAL_GROUP(Remote Desktop Users), BROKER_API

set -eu

# --- Variables ---
USER_EMAIL="${BRITIVE_USER_EMAIL:-}"
TRANSACTION_ID="${TRX:-}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_PORT="${TARGET_PORT:-3389}"
BRIDGE_URL="${BRIDGE_URL:-}"
EXPIRATION="${EXPIRATION:-}"
PROVISION_HOST="${PROVISION_HOST:-${TARGET_HOST}}"
PROVISION_TRANSPORT="${PROVISION_TRANSPORT:-winrm}"
PROVISION_USER="${PROVISION_USER:-Administrator}"
PROVISION_PASSWORD="${PROVISION_PASSWORD:-}"
PROVISION_KEY="${PROVISION_KEY:-/home/bridge/.ssh/id_ed25519}"
PROVISION_KEY_PEM="${PROVISION_KEY_PEM:-}"
WINRM_NO_SSL="${WINRM_NO_SSL:-1}"
LOCAL_GROUP="${LOCAL_GROUP:-Remote Desktop Users}"
BRITIVE_FIRST_NAME="${BRITIVE_FIRST_NAME:-}"
BRITIVE_LAST_NAME="${BRITIVE_LAST_NAME:-}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/bridge.sh}"

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

for var in BRITIVE_USER_EMAIL TRX TARGET_HOST BRIDGE_URL EXPIRATION; do
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

# --- Derive Windows username (SAM: [a-z0-9], max 20 chars) ---
USERNAME="$(python3 -c "
import re, sys
name = re.sub(r'[^a-z0-9]', '', sys.argv[1].split('@')[0].lower())
if not name:
    sys.exit('error: cannot derive username from: ' + sys.argv[1])
if name[0].isdigit():
    name = 'brg' + name
print(name[:20])
" "$USER_EMAIL")"

# --- Display name: "First Last" if available, else email local part ---
if [ -n "$BRITIVE_FIRST_NAME" ] && [ -n "$BRITIVE_LAST_NAME" ]; then
    FULLNAME="${BRITIVE_FIRST_NAME} ${BRITIVE_LAST_NAME}"
else
    FULLNAME="${USER_EMAIL%%@*}"
fi

# --- Generate password (meets Windows complexity: upper+lower+digit+special) ---
RAND="$(head -c 12 /dev/urandom | base64 | tr -d "+/='\\\\" | head -c 12)"
PASSWORD="${RAND}Aa1@"

# --- Temp files & cleanup ---
PAYLOAD_FILE="$(mktemp)"
PS_FILE=""
KEY_FILE=""
trap 'rm -f "$PAYLOAD_FILE" ${PS_FILE:+"$PS_FILE"} ${KEY_FILE:+"$KEY_FILE"}' EXIT INT TERM
umask 077

if [ "$PROVISION_TRANSPORT" = "ssh" ] && [ -n "$PROVISION_KEY_PEM" ]; then
    KEY_FILE="$(mktemp -p /dev/shm 2>/dev/null || mktemp)"
    printf '%s\n' "$PROVISION_KEY_PEM" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    PROVISION_KEY="$KEY_FILE"
fi

# --- PowerShell provisioning script ---
PS_CHECKOUT="$(cat <<PS_EOF
\$ProgressPreference = 'SilentlyContinue'
try {
    \$username = '${USERNAME}'
    \$fullname = '${FULLNAME}'
    \$pw       = ConvertTo-SecureString '${PASSWORD}' -AsPlainText -Force
    \$groups   = '${LOCAL_GROUP}'.Split(',') | ForEach-Object { \$_.Trim() } | Where-Object { \$_ -ne '' }

    if (-not (Get-LocalUser -Name \$username -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name \$username -Password \$pw -Description 'bridge:${TRANSACTION_ID}' -FullName \$fullname -PasswordNeverExpires | Out-Null
        Write-Output ('Created user: ' + \$username)
    } else {
        Set-LocalUser -Name \$username -Password \$pw -FullName \$fullname
        Write-Output ('Reset password for existing user: ' + \$username)
    }
    foreach (\$group in \$groups) {
        try {
            Add-LocalGroupMember -Group \$group -Member \$username -ErrorAction Stop
            Write-Output ('Added to group: ' + \$group)
        } catch {
            if (\$_.Exception.Message -like '*already a member*') {
                Write-Output ('Already in group: ' + \$group)
            } else {
                throw
            }
        }
    }
    Write-Output 'SUCCESS'
} catch {
    Write-Output ('PSERROR: ' + \$_.Exception.Message)
    exit 1
}
PS_EOF
)"

# --- Provision user on Windows target ---
echo "[checkout] provisioning ${USERNAME} on ${PROVISION_HOST} via ${PROVISION_TRANSPORT}" >&2

case "$PROVISION_TRANSPORT" in
    winrm)
        PS_FILE="$(mktemp)"
        printf '%s' "$PS_CHECKOUT" > "$PS_FILE"

        WINRM_SCHEME="https"
        [ "$WINRM_NO_SSL" = "1" ] && WINRM_SCHEME="http"

        PROVISION_HOST="$PROVISION_HOST" \
        PROVISION_USER="$PROVISION_USER" \
        PROVISION_PASSWORD="$PROVISION_PASSWORD" \
        PROVISION_PORT="$PROVISION_PORT" \
        WINRM_SCHEME="$WINRM_SCHEME" \
        PS_FILE="$PS_FILE" \
        python3 - <<'PYEOF'
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

target_url = '{}://{}:{}/wsman'.format(scheme, host, port)

try:
    session = winrm.Session(
        target=target_url,
        auth=(user, password),
        transport='ntlm',
        server_cert_validation='ignore',
        read_timeout_sec=20,
        operation_timeout_sec=15,
    )
    result = session.run_ps(script)
except Exception as e:
    sys.stderr.write('[checkout] WinRM error: {}\n'.format(e))
    sys.exit(1)

ps_out = result.std_out.decode('utf-8', 'replace').strip()
ps_err = result.std_err.decode('utf-8', 'replace').strip()

if ps_out:
    sys.stderr.write('[checkout] {}\n'.format(ps_out))
if ps_err:
    sys.stderr.write('[checkout] PS stderr: {}\n'.format(ps_err))

if result.status_code != 0:
    sys.stderr.write('[checkout] PS failed (status_code={})\n'.format(result.status_code))
    sys.exit(1)
PYEOF
        ;;
    ssh)
        ENCODED="$(printf '%s' "$PS_CHECKOUT" | \
            python3 -c 'import sys, base64; print(base64.b64encode(sys.stdin.read().encode("utf-16-le")).decode())')"
        ssh -i "$PROVISION_KEY" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -o BatchMode=yes \
            -p "$PROVISION_PORT" \
            "${PROVISION_USER}@${PROVISION_HOST}" \
            "powershell.exe -NonInteractive -EncodedCommand ${ENCODED}" >/dev/null
        ;;
esac

echo "[checkout] user provisioned" >&2

# --- Build Bridge payload & register session ---
TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
EXPIRES_AT="$(($(date +%s) + EXPIRATION))"
PASSWORD_JSON="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$PASSWORD")"

cat > "$PAYLOAD_FILE" <<EOF
{
  "transaction_id":  "${TRANSACTION_ID}",
  "protocol":        "rdp",
  "username":        "${USER_EMAIL}",
  "target_host":     "${TARGET_HOST}",
  "target_port":     ${TARGET_PORT},
  "target_username": "${USERNAME}",
  "target_password": ${PASSWORD_JSON},
  "expires_at":      ${EXPIRES_AT},
  "token":           "${TOKEN}"
}
EOF

"${BROKER_API}" checkout-create --file "$PAYLOAD_FILE" >/dev/null
echo "[checkout] Bridge session registered" >&2

# --- Output ---
URL="${BRIDGE_URL}/rdp/#token=${TOKEN}&transaction_id=${TRANSACTION_ID}"
printf '{"token": "%s", "url": "%s"}\n' "${TOKEN}" "${URL}"
