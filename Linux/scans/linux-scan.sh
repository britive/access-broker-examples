#!/bin/sh
set -eu

# ============================================================
# Linux VM IAM-Style Broker Scan (remote)
# ============================================================
# Runs on the Britive broker. SSHes into a target Linux VM,
# enumerates local users and groups (and group membership),
# builds a JSON payload in the Britive Resource Manager schema,
# and writes it to the path supplied by the broker.
#
# The scan logic itself runs ON the remote VM (embedded POSIX
# shell below), reading /etc/passwd and /etc/group via getent.
# The broker captures the remote stdout and writes it to disk.
#
# Required env var:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH  – full path for JSON output
#
# Broker-injected resource params (plaintext), same as the
# temp-ssh-key-remote checkout/checkin scripts:
#   RESOURCE_HOST          – target server hostname/IP        (required)
#   RESOURCE_USER          – remote provisioning ssh user     (default: britivebroker)
#   RESOURCE_KEY_LOCATION  – path to the provisioning user's private key
#                            (default: /home/britivebroker/.ssh/MYKEY.pem)
#
# Optional:
#   SCAN_MIN_UID           – lowest UID to include            (default: 0 = all)
#
# (Legacy names BRITIVE_REMOTE_HOST/HOST, REMOTE_USER, REMOTE_KEY are still
#  honored as fallbacks.)
#
# Identity IDs use the local username so that
# attribute_resolution.group_membership = "id" resolves correctly.
# ============================================================

# ---- broker-side validation -------------------------------
if [ -z "${BROKER_INJECTED_SCAN_OUTPUT_PATH:-}" ]; then
    echo "ERROR: BROKER_INJECTED_SCAN_OUTPUT_PATH not set. Cannot write scan output." >&2
    exit 1
fi
OUTPUT_PATH="$BROKER_INJECTED_SCAN_OUTPUT_PATH"

REMOTE_HOST="${RESOURCE_HOST:-${BRITIVE_REMOTE_HOST:-${HOST:-}}}"
REMOTE_USER="${RESOURCE_USER:-${REMOTE_USER:-britivebroker}}"
REMOTE_KEY="${RESOURCE_KEY_LOCATION:-${REMOTE_KEY:-/home/britivebroker/.ssh/MYKEY.pem}}"
SCAN_MIN_UID="${SCAN_MIN_UID:-0}"

OUT_DIR="$(dirname "$OUTPUT_PATH")"
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"

# ---- error JSON helper ------------------------------------
# write_error <message>
write_error() {
    _msg="$1"
    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # escape quotes/backslashes in the message for JSON
    _msg_esc="$(printf '%s' "$_msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    cat > "$OUTPUT_PATH" <<EOF
{
  "data": { "identities": [], "groups": [], "permissions": [], "permission_mapping": [] },
  "metadata": { "scan_errors": "$_msg_esc", "scan_time": "$_now" }
}
EOF
}

# ---- fail-fast connection checks --------------------------
[ -z "$REMOTE_HOST" ]  && { write_error "RESOURCE_HOST empty — set RESOURCE_HOST"; echo "ERROR: RESOURCE_HOST empty" >&2; exit 1; }
[ -f "$REMOTE_KEY" ]   || { write_error "SSH key not found at $REMOTE_KEY (RESOURCE_KEY_LOCATION)"; echo "ERROR: SSH key not found at $REMOTE_KEY" >&2; exit 1; }

echo "Running Linux VM IAM-style broker scan against $REMOTE_HOST..."
echo "Output path: $OUTPUT_PATH"

# ---- run the scanner on the remote VM, capture stdout -----
TMP_OUT="$(mktemp)"
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_OUT" "$TMP_ERR"' EXIT INT TERM

set +e
ssh \
    -i "$REMOTE_KEY" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$REMOTE_USER@$REMOTE_HOST" \
    sh -s -- "$SCAN_MIN_UID" > "$TMP_OUT" 2> "$TMP_ERR" <<'REMOTE'
set -eu
MIN_UID="${1:-0}"

# JSON string escaper: backslash, double-quote, tab, CR, newline.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g'
}

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# hostname resolution: prefer FQDN, fall back to short name, then uname -n
# (the `hostname` binary is not installed by default on Amazon Linux 2023 minimal).
HOSTID="$(hostname -f 2>/dev/null || hostname 2>/dev/null || uname -n)"

# ---- USERS (local accounts from getent passwd) ----
# An account is treated as active when its login shell is not a
# nologin/false shell and the account is not locked in /etc/shadow.
IDENT_JSON=""
first=1
while IFS=: read -r uname pw uid gid gecos home shell; do
    # skip malformed lines with a non-numeric UID (would break the -lt test
    # and, under set -e, abort the whole scan)
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -lt "$MIN_UID" ] && continue
    active=true
    case "$shell" in
        */nologin|*/false|/bin/sync|/sbin/nologin|/usr/sbin/nologin) active=false ;;
    esac
    # locked account check (best-effort; needs shadow read access)
    if [ "$active" = true ]; then
        sp="$(getent shadow "$uname" 2>/dev/null | cut -d: -f2 || true)"
        case "$sp" in
            '!'*|'*'*) active=false ;;
        esac
    fi
    fn="$(printf '%s' "$gecos" | cut -d, -f1 | awk '{print $1}')"
    ln="$(printf '%s' "$gecos" | cut -d, -f1 | awk '{$1=""; sub(/^ /,""); print}')"
    [ -z "$fn" ] && fn="NA"
    [ -z "$ln" ] && ln="NA"
    rec="{\"id\":\"$(esc "$uname")\",\"name\":\"$(esc "$uname")\",\"type\":\"User\",\"description\":\"Local Linux user\",\"created_on\":\"$NOW\",\"is_active\":$active,\"attributes\":{\"username\":\"$(esc "$uname")\",\"email\":\"$(esc "$uname")@$(esc "$HOSTID")\",\"uid\":\"$(esc "$uid")\",\"gid\":\"$(esc "$gid")\",\"first_name\":\"$(esc "$fn")\",\"last_name\":\"$(esc "$ln")\",\"gecos\":\"$(esc "$gecos")\",\"home\":\"$(esc "$home")\",\"shell\":\"$(esc "$shell")\"}}"
    if [ $first -eq 1 ]; then IDENT_JSON="$rec"; first=0; else IDENT_JSON="$IDENT_JSON,$rec"; fi
done <<EOF
$(getent passwd)
EOF

# ---- GROUPS (from getent group, plus primary-group members) ----
GROUP_JSON=""
gfirst=1
while IFS=: read -r gname gpw ggid gmembers; do
    # collect secondary members listed on the group line
    mlist="$gmembers"
    # add users whose PRIMARY gid == this group's gid
    prim="$(getent passwd | awk -F: -v g="$ggid" '$4==g {print $1}' | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$prim" ]; then
        if [ -n "$mlist" ]; then mlist="$mlist,$prim"; else mlist="$prim"; fi
    fi
    # build deduplicated JSON array of member usernames
    members_arr=""
    mfirst=1
    seen=" "
    OLDIFS="$IFS"; IFS=','
    for m in $mlist; do
        [ -z "$m" ] && continue
        case "$seen" in *" $m "*) continue ;; esac
        seen="$seen$m "
        if [ $mfirst -eq 1 ]; then members_arr="\"$(esc "$m")\""; mfirst=0; else members_arr="$members_arr,\"$(esc "$m")\""; fi
    done
    IFS="$OLDIFS"
    grec="{\"id\":\"$(esc "$gname")\",\"name\":\"$(esc "$gname")\",\"type\":\"User group\",\"description\":\"Local Linux group\",\"created_on\":\"$NOW\",\"is_active\":true,\"members\":[$members_arr],\"attributes\":{\"groupname\":\"$(esc "$gname")\",\"gid\":\"$(esc "$ggid")\"}}"
    if [ $gfirst -eq 1 ]; then GROUP_JSON="$grec"; gfirst=0; else GROUP_JSON="$GROUP_JSON,$grec"; fi
done <<EOF
$(getent group)
EOF

# ---- assemble Britive Resource Manager schema ----
cat <<EOF
{
  "data": {
    "identities": [$IDENT_JSON],
    "groups": [$GROUP_JSON],
    "permissions": [],
    "permission_mapping": []
  },
  "metadata": {
    "resource_id": "$(esc "$HOSTID")",
    "resource_type": "LinuxVM",
    "scan_time": "$NOW",
    "scan_details": "Linux VM scan completed on $(esc "$HOSTID").",
    "scan_errors": "",
    "attribute_resolution": {
      "group_membership": "id",
      "permission_mapping": "id"
    }
  }
}
EOF
REMOTE
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
    ERRMSG="$(cat "$TMP_ERR")"
    [ -z "$ERRMSG" ] && ERRMSG="Remote scan failed with exit code $RC"
    echo "Scan failed: $ERRMSG" >&2
    write_error "$ERRMSG"
    exit 1
fi

# ---- validate the captured output before writing it out ----
# The remote block emits its JSON only as its final action, so a non-empty
# object starting with '{' means the scan ran to completion.
if [ ! -s "$TMP_OUT" ]; then
    ERRMSG="Remote scan returned no output (stderr: $(cat "$TMP_ERR"))"
    echo "Scan failed: $ERRMSG" >&2
    write_error "$ERRMSG"
    exit 1
fi
case "$(head -c 1 "$TMP_OUT" 2>/dev/null)" in
    '{') : ;;
    *)
        ERRMSG="Remote scan produced non-JSON output"
        echo "Scan failed: $ERRMSG" >&2
        write_error "$ERRMSG"
        exit 1
        ;;
esac

# ---- write the JSON to the broker output path -------------
# Explicit write check: if the broker path is unwritable (perms/disk), fail
# loudly rather than exiting 0 with no/partial output.
if ! cat "$TMP_OUT" > "$OUTPUT_PATH"; then
    echo "ERROR: failed to write scan output to $OUTPUT_PATH" >&2
    exit 1
fi

echo "Linux VM broker scan completed successfully."
exit 0
