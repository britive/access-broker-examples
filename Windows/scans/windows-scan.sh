#!/bin/sh
set -eu

# ============================================================
# Windows VM IAM-Style Broker Scan (runs on the Linux broker)
# ============================================================
# Shell version of windows_scan_provision.ps1. Instead of PowerShell
# remoting from a Windows broker, this runs on the Linux broker and
# reaches the Windows target the same way the temp-user-bridge scripts
# do — WinRM (python3 + pywinrm) or SSH (powershell.exe -EncodedCommand).
#
# A PowerShell block runs ON the target, enumerates local users and
# groups, and emits the Britive Resource Manager JSON on stdout. The
# broker captures it, validates it, and writes it to the output path.
#
# Broker-injected resource params (plaintext env vars):
#   RESOURCE_HOST                 – target VM hostname/IP        (required)
#   RESOURCE_PROVISION_USERNAME   – WinRM/SSH admin user         (default: Administrator)
#   RESOURCE_PROVISION_PASSWORD   – admin password (required for winrm)
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH – full path for JSON output (required)
#
# Optional:
#   PROVISION_TRANSPORT – winrm (default) or ssh
#   PROVISION_HOST      – host to connect to (default: RESOURCE_HOST)
#   PROVISION_PORT      – default 5985/5986 (winrm) or 22 (ssh)
#   WINRM_NO_SSL        – 1 for HTTP/5985 (default: 1), 0 for HTTPS/5986
#   PROVISION_KEY       – SSH private key path (default: /home/bridge/.ssh/id_ed25519)
#   PROVISION_KEY_PEM   – inline PEM content of the SSH key (preferred; tmpfs)
#
# Basic/NTLM over HTTP requires WinRM 'AllowUnencrypted=true' on the
# target (or use HTTPS/5986).
# ============================================================

# ---- broker-side validation -------------------------------
if [ -z "${BROKER_INJECTED_SCAN_OUTPUT_PATH:-}" ]; then
    echo "ERROR: BROKER_INJECTED_SCAN_OUTPUT_PATH not set. Cannot write scan output." >&2
    exit 1
fi
OUTPUT_PATH="$BROKER_INJECTED_SCAN_OUTPUT_PATH"

TARGET_HOST="${RESOURCE_HOST:-}"
PROVISION_USER="${RESOURCE_PROVISION_USERNAME:-Administrator}"
PROVISION_PASSWORD="${RESOURCE_PROVISION_PASSWORD:-}"
PROVISION_TRANSPORT="${PROVISION_TRANSPORT:-winrm}"
PROVISION_HOST="${PROVISION_HOST:-${TARGET_HOST}}"
PROVISION_KEY="${PROVISION_KEY:-/home/bridge/.ssh/id_ed25519}"
PROVISION_KEY_PEM="${PROVISION_KEY_PEM:-}"
WINRM_NO_SSL="${WINRM_NO_SSL:-1}"

if [ "$PROVISION_TRANSPORT" = "winrm" ]; then
    if [ "$WINRM_NO_SSL" = "1" ]; then
        PROVISION_PORT="${PROVISION_PORT:-5985}"
    else
        PROVISION_PORT="${PROVISION_PORT:-5986}"
    fi
else
    PROVISION_PORT="${PROVISION_PORT:-22}"
fi

OUT_DIR="$(dirname "$OUTPUT_PATH")"
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"

# ---- error JSON helper ------------------------------------
# write_error <message>
write_error() {
    _msg="$1"
    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _msg_esc="$(printf '%s' "$_msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    cat > "$OUTPUT_PATH" <<EOF
{
  "data": { "identities": [], "groups": [], "permissions": [], "permission_mapping": [] },
  "metadata": { "scan_errors": "$_msg_esc", "scan_time": "$_now" }
}
EOF
}

# ---- fail-fast checks -------------------------------------
[ -n "$TARGET_HOST" ] || { write_error "RESOURCE_HOST empty"; echo "ERROR: RESOURCE_HOST empty" >&2; exit 1; }

case "$PROVISION_TRANSPORT" in
    winrm)
        command -v python3 >/dev/null 2>&1 || { write_error "python3 not found on broker"; echo "ERROR: python3 not found" >&2; exit 1; }
        python3 -c "import winrm" 2>/dev/null || { write_error "pywinrm not installed (pip install pywinrm)"; echo "ERROR: pywinrm not installed" >&2; exit 1; }
        [ -n "$PROVISION_PASSWORD" ] || { write_error "RESOURCE_PROVISION_PASSWORD required for winrm transport"; echo "ERROR: password required for winrm" >&2; exit 1; }
        ;;
    ssh)
        command -v ssh >/dev/null 2>&1 || { write_error "ssh not found on broker"; echo "ERROR: ssh not found" >&2; exit 1; }
        [ -n "$PROVISION_KEY_PEM" ] || [ -f "$PROVISION_KEY" ] || { write_error "ssh transport requires PROVISION_KEY_PEM or key at $PROVISION_KEY"; echo "ERROR: ssh key missing" >&2; exit 1; }
        command -v python3 >/dev/null 2>&1 || { write_error "python3 required to base64-encode the PowerShell command"; echo "ERROR: python3 not found" >&2; exit 1; }
        ;;
    *) write_error "PROVISION_TRANSPORT must be 'winrm' or 'ssh' (got: $PROVISION_TRANSPORT)"; echo "ERROR: bad transport" >&2; exit 1 ;;
esac

echo "Running Windows VM broker scan against $TARGET_HOST via $PROVISION_TRANSPORT..." >&2
echo "Output path: $OUTPUT_PATH" >&2

# ---- temp files & cleanup ---------------------------------
TMP_OUT="$(mktemp)"
TMP_ERR="$(mktemp)"
PS_FILE=""
KEY_FILE=""
trap 'rm -f "$TMP_OUT" "$TMP_ERR" ${PS_FILE:+"$PS_FILE"} ${KEY_FILE:+"$KEY_FILE"}' EXIT INT TERM
umask 077

if [ "$PROVISION_TRANSPORT" = "ssh" ] && [ -n "$PROVISION_KEY_PEM" ]; then
    KEY_FILE="$(mktemp -p /dev/shm 2>/dev/null || mktemp)"
    printf '%s\n' "$PROVISION_KEY_PEM" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    PROVISION_KEY="$KEY_FILE"
fi

# ---- PowerShell scan block (runs ON the target) -----------
# Enumerates local users/groups and emits the Britive Resource Manager
# JSON on stdout. Emits ONLY the JSON (or 'PSERROR: ...' on failure) so
# the broker can capture it cleanly.
PS_SCAN="$(cat <<'PS_EOF'
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
try {
    $now      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $computer = $env:COMPUTERNAME

    $identities = @()
    foreach ($u in Get-LocalUser) {
        $fn = "NA"; $ln = "NA"
        if ($u.FullName) {
            $parts = $u.FullName.Trim() -split '\s+', 2
            $fn = $parts[0]
            if ($parts.Count -gt 1) { $ln = $parts[1] }
        }
        $identities += @{
            id          = $u.Name
            name        = $u.Name
            type        = "User"
            description = "Local Windows user"
            created_on  = $now
            is_active   = [bool]$u.Enabled
            attributes  = @{
                username   = $u.Name
                email      = "$($u.Name)@$computer.local"
                sid        = $u.SID.Value
                first_name = $fn
                last_name  = $ln
                full_name  = if ($u.FullName) { $u.FullName } else { "" }
                user_desc  = if ($u.Description) { $u.Description } else { "" }
            }
        }
    }

    $groups = @()
    foreach ($g in Get-LocalGroup) {
        $members = @()
        try {
            Get-LocalGroupMember -Group $g.Name -ErrorAction Stop | ForEach-Object {
                if ($_.ObjectClass -eq 'User') { $members += ($_.Name -split '\\')[-1] }
            }
        } catch {
            # some built-in groups may deny enumeration
        }
        $groups += @{
            id          = $g.Name
            name        = $g.Name
            type        = "User group"
            description = "Local Windows group"
            created_on  = $now
            is_active   = $true
            members     = $members
            attributes  = @{
                groupname  = $g.Name
                sid        = $g.SID.Value
                group_desc = if ($g.Description) { $g.Description } else { "" }
            }
        }
    }

    $output = @{
        data = @{
            identities         = $identities
            groups             = $groups
            permissions        = @()
            permission_mapping = @()
        }
        metadata = @{
            resource_id   = $computer
            resource_type = "WindowsVM"
            scan_time     = $now
            scan_details  = "Windows VM scan completed on $computer. Users: $($identities.Count), Groups: $($groups.Count)"
            scan_errors   = ""
            attribute_resolution = @{
                group_membership   = "id"
                permission_mapping = "id"
            }
        }
    }

    $output | ConvertTo-Json -Depth 10
} catch {
    Write-Output ('PSERROR: ' + $_.Exception.Message)
    exit 1
}
PS_EOF
)"

# ---- run the scan on the target, capture JSON on stdout ----
set +e
case "$PROVISION_TRANSPORT" in
    winrm)
        PS_FILE="$(mktemp)"
        printf '%s' "$PS_SCAN" > "$PS_FILE"

        WINRM_SCHEME="https"
        [ "$WINRM_NO_SSL" = "1" ] && WINRM_SCHEME="http"

        PROVISION_HOST="$PROVISION_HOST" \
        PROVISION_USER="$PROVISION_USER" \
        PROVISION_PASSWORD="$PROVISION_PASSWORD" \
        PROVISION_PORT="$PROVISION_PORT" \
        WINRM_SCHEME="$WINRM_SCHEME" \
        PS_FILE="$PS_FILE" \
        python3 - > "$TMP_OUT" 2> "$TMP_ERR" <<'PYEOF'
import os, sys

try:
    import winrm
except ImportError:
    sys.stderr.write("pywinrm not installed\n")
    sys.exit(1)

host     = os.environ['PROVISION_HOST']
user     = os.environ['PROVISION_USER']
password = os.environ['PROVISION_PASSWORD']
port     = int(os.environ.get('PROVISION_PORT', '5985'))
scheme   = os.environ.get('WINRM_SCHEME', 'http')

with open(os.environ['PS_FILE']) as f:
    script = f.read()

try:
    session = winrm.Session(
        target='{}://{}:{}/wsman'.format(scheme, host, port),
        auth=(user, password),
        transport='ntlm',
        server_cert_validation='ignore',
        read_timeout_sec=70,
        operation_timeout_sec=60,
    )
    result = session.run_ps(script)
except Exception as e:
    sys.stderr.write('WinRM error: {}\n'.format(e))
    sys.exit(1)

out = result.std_out.decode('utf-8', 'replace')
err = result.std_err.decode('utf-8', 'replace').strip()

if result.status_code != 0:
    sys.stderr.write('PS failed (status={}): {} {}\n'.format(result.status_code, out.strip(), err))
    sys.exit(1)

# emit ONLY the PowerShell stdout (the JSON) so the broker can capture it
sys.stdout.write(out)
PYEOF
        ;;
    ssh)
        ENCODED="$(printf '%s' "$PS_SCAN" | \
            python3 -c 'import sys, base64; print(base64.b64encode(sys.stdin.read().encode("utf-16-le")).decode())')"
        ssh -i "$PROVISION_KEY" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -o BatchMode=yes \
            -p "$PROVISION_PORT" \
            "${PROVISION_USER}@${PROVISION_HOST}" \
            "powershell.exe -NonInteractive -EncodedCommand ${ENCODED}" > "$TMP_OUT" 2> "$TMP_ERR"
        ;;
esac
RC=$?
set -e

# ---- transport / remote failure ---------------------------
if [ "$RC" -ne 0 ]; then
    ERRMSG="$(cat "$TMP_ERR")"
    [ -z "$ERRMSG" ] && ERRMSG="Remote scan failed with exit code $RC"
    echo "Scan failed: $ERRMSG" >&2
    write_error "$ERRMSG"
    exit 1
fi

# ---- normalize and validate captured output --------------
# PowerShell over SSH/WinRM may emit CRLF and a leading UTF-8 BOM; strip both
# so the result is clean JSON.
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$TMP_OUT" > "$TMP_OUT.clean" && mv "$TMP_OUT.clean" "$TMP_OUT"

if [ ! -s "$TMP_OUT" ]; then
    write_error "Remote scan returned no output (stderr: $(cat "$TMP_ERR"))"
    echo "ERROR: empty scan output" >&2
    exit 1
fi

# a PowerShell error surfaces as 'PSERROR: ...' on stdout
if head -n 1 "$TMP_OUT" | grep -q '^PSERROR:'; then
    ERRMSG="$(cat "$TMP_OUT")"
    echo "Scan failed: $ERRMSG" >&2
    write_error "$ERRMSG"
    exit 1
fi

# must be a JSON object
case "$(sed -e 's/^[[:space:]]*//' "$TMP_OUT" | head -c 1)" in
    '{') : ;;
    *) write_error "Remote scan produced non-JSON output"; echo "ERROR: non-JSON output" >&2; exit 1 ;;
esac

# ---- write the JSON to the broker output path -------------
if ! cat "$TMP_OUT" > "$OUTPUT_PATH"; then
    echo "ERROR: failed to write scan output to $OUTPUT_PATH" >&2
    exit 1
fi

echo "Windows VM broker scan completed successfully." >&2
exit 0
