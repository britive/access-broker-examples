#!/bin/bash
#
# Britive checkout script: temp Windows user + Bridge (v2) proxied RDP session
#
# Creates a temporary local Windows user (via WinRM or SSH), then registers an
# RDP checkout with the Bridge. The user connects with a native RDP client
# pointed at the Bridge's RDP listener, or through the in-browser desktop.
# The Windows account password never leaves the broker/Bridge.
#
# Bridge authentication: the user authenticates to the Bridge proxy with the
# Bridge Username/Password set on their Britive profile (Manage Account ->
# Bridge Attributes) -- no per-checkout Bridge credentials are generated here.
#
# Required env vars (set by Britive Resource Type / Profile):
#   BRITIVE_USER_EMAIL - requesting user's email (username derived from local part)
#   TRX                - Britive transaction ID
#   TARGET_HOST        - Windows RDP target host
#   BRIDGE_URL         - Bridge hostname users connect to (e.g. bridge.example.com)
#   EXPIRATION         - Checkout duration in seconds
#
# Optional env vars (with defaults):
#   TARGET_PORT         - RDP port on the target (default: 3389)
#   TARGET_DOMAIN       - Windows/AD domain for the RDP login (default: none)
#   NATIVE_PORT         - Bridge native RDP listener port (default: 3389)
#   RDP_SECURITY        - any | nla | tls | rdp (default: nla)
#   RDP_ENABLE_DRIVE    - true/false, allow drive redirection (default: false)
#   BRITIVE_FIRST_NAME / BRITIVE_LAST_NAME - used for the account display name
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
TARGET_PORT="${TARGET_PORT:-3389}"
TARGET_DOMAIN="${TARGET_DOMAIN:-}"
NATIVE_PORT="${NATIVE_PORT:-3389}"
RDP_SECURITY="${RDP_SECURITY:-nla}"
RDP_ENABLE_DRIVE="${RDP_ENABLE_DRIVE:-false}"
BRIDGE_URL="${BRIDGE_URL:-}"
EXPIRATION="${EXPIRATION:-}"
LOCAL_GROUP="${LOCAL_GROUP:-Remote Desktop Users}"
PROVISION_TRANSPORT="${PROVISION_TRANSPORT:-winrm}"
PROVISION_HOST="${PROVISION_HOST:-${TARGET_HOST}}"
PROVISION_USER="${PROVISION_USER:-Administrator}"
PROVISION_PASSWORD="${PROVISION_PASSWORD:-}"
PROVISION_KEY="${PROVISION_KEY:-/home/bridge/.ssh/id_ed25519}"
PROVISION_KEY_PEM="${PROVISION_KEY_PEM:-}"
WINRM_NO_SSL="${WINRM_NO_SSL:-1}"
BRITIVE_FIRST_NAME="${BRITIVE_FIRST_NAME:-}"
BRITIVE_LAST_NAME="${BRITIVE_LAST_NAME:-}"
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

for var in BRITIVE_USER_EMAIL TRX TARGET_HOST BRIDGE_URL EXPIRATION; do
    eval "val=\${$var:-}"
    [ -n "$val" ] || fail "required env var missing: $var"
done

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

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

# --- Generate account password (meets Windows complexity) ---
# Only the Bridge ever sees it -- the user gets a Bridge password instead
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

# --- Register the Bridge checkout ---
TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
EXPIRES_AT="$(($(date +%s) + EXPIRATION))"
PASSWORD_JSON="$(jq -Rn --arg p "$PASSWORD" '$p')"

DOMAIN_FIELD=""
if [ -n "$TARGET_DOMAIN" ]; then
    DOMAIN_FIELD="\"target_domain\": \"${TARGET_DOMAIN}\","
fi

cat > "$PAYLOAD_FILE" <<EOF
{
  "transaction_id": "${TRANSACTION_ID}",
  "protocol": "rdp",
  "username": "${USER_EMAIL}",
  "target_host": "${TARGET_HOST}",
  "target_port": ${TARGET_PORT},
  "target_username": "${USERNAME}",
  "target_password": ${PASSWORD_JSON},
  ${DOMAIN_FIELD}
  "rdp_security": "${RDP_SECURITY}",
  "rdp_enable_drive": ${RDP_ENABLE_DRIVE},
  "record_session": true,
  "expires_at": ${EXPIRES_AT},
  "token": "${TOKEN}"
}
EOF

"${BROKER_API}" checkout-create --file "$PAYLOAD_FILE" >/dev/null || \
    fail "Bridge checkout registration failed"
echo "[checkout] Bridge session registered" >&2

# --- Output connection details ---
# Standard Bridge checkout output schema (shared across ssh/rdp/db checkouts
# so a single response template works for all):
#   BRIDGE_URL, command, bridge_username, bridge_port, target_username,
#   browser_session, token
# BRIDGE_URL is the Bridge hostname (bridge.example.com) — the same host the
# user's RDP client connects to as <bridge-username>%<target-host>,
# authenticating with the Bridge Password from their Britive profile.
# Bridge Username defaults to the email local part (alphanumeric only).
BRIDGE_HOST="${BRIDGE_URL#https://}"
BRIDGE_HOST="${BRIDGE_HOST#http://}"
BRIDGE_HOST="${BRIDGE_HOST%%[:/]*}"
BRIDGE_USER="${USER_EMAIL%%@*}"
BRIDGE_USER="${BRIDGE_USER//[^a-zA-Z0-9]/}"
NATIVE_USER="${BRIDGE_USER}%${TARGET_HOST}"
COMMAND="mstsc /v:${BRIDGE_HOST}:${NATIVE_PORT}"
BROWSER_SESSION="https://${BRIDGE_HOST}/connect?transaction_id=${TRANSACTION_ID}"

jq -n \
  --arg BRIDGE_URL "$BRIDGE_HOST" \
  --arg command "$COMMAND" \
  --arg bridge_username "$NATIVE_USER" \
  --arg bridge_port "$NATIVE_PORT" \
  --arg target_username "$USERNAME" \
  --arg browser_session "$BROWSER_SESSION" \
  --arg token "$TOKEN" \
  '{BRIDGE_URL: $BRIDGE_URL, command: $command,
    bridge_username: $bridge_username, bridge_port: $bridge_port,
    target_username: $target_username, browser_session: $browser_session,
    token: $token}'
