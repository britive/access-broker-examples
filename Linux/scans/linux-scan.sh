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
# Connection env vars (mirror the temp-ssh-key-remote scripts):
#   BRITIVE_REMOTE_HOST (or HOST)  – target VM hostname/IP   (required)
#   REMOTE_USER                    – ssh login user          (default: britivebroker)
#   REMOTE_KEY                     – broker private key path  (default: /home/britivebroker/.ssh/MYKEY.pem)
#   SCAN_MIN_UID                   – lowest UID to include    (default: 0 = all)
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

REMOTE_HOST="${BRITIVE_REMOTE_HOST:-${HOST:-}}"
REMOTE_USER="${REMOTE_USER:-britivebroker}"
REMOTE_KEY="${REMOTE_KEY:-/home/britivebroker/.ssh/MYKEY.pem}"
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
[ -z "$REMOTE_HOST" ]  && { write_error "REMOTE_HOST empty — set BRITIVE_REMOTE_HOST"; echo "ERROR: REMOTE_HOST empty" >&2; exit 1; }
[ -f "$REMOTE_KEY" ]   || { write_error "SSH key not found at $REMOTE_KEY"; echo "ERROR: SSH key not found at $REMOTE_KEY" >&2; exit 1; }

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
HOSTID="$(hostname -f 2>/dev/null || hostname)"

# ---- USERS (local accounts from getent passwd) ----
# An account is treated as active when its login shell is not a
# nologin/false shell and the account is not locked in /etc/shadow.
IDENT_JSON=""
first=1
while IFS=: read -r uname pw uid gid gecos home shell; do
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

# move captured remote JSON to the broker output path
cat "$TMP_OUT" > "$OUTPUT_PATH"
echo "Linux VM broker scan completed successfully."
exit 0
