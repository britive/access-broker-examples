#!/bin/bash
# ============================================================
# SYNOPSIS
#     CrowdStrike Falcon RTR script to remove a user from the local admin
#     group and automatically display a notification in the user's GUI session.
#
# DESCRIPTION
#     Accepts a macOS username as a parameter, removes it from the admin group,
#     verifies removal, then immediately pops up a dialog in the user's
#     active GUI session — no launcher files, no manual action required.
# NOTES
#     Requires:       RTR Admin or RTR Active Responder role with runscript permission
#     Impact:         A notification dialog appears on the user's screen automatically.
#
#     STATUS CONTRACT
#     RTR reports command delivery, not script outcome — the exit code never
#     reaches the caller. The last line of stdout is therefore the machine
#     -readable result:
#
#         BRITIVE_STATUS {"status":"success|error","action":"de-elevate", ...}
#
#     Callers must parse the LAST line matching '^BRITIVE_STATUS ' and treat a
#     missing marker as an error (timeout, kill, or truncated output).
#
#     Revocation is idempotent: an account that is already not an admin, or that
#     no longer exists on the host, reports success. The desired end state is
#     reached either way, and Britive retries check-in.
# ============================================================

set -e
set -u
set -o pipefail

# ============================================================
# Status marker plumbing
#   Defaults are pessimistic: if the script dies anywhere without
#   reaching an explicit outcome, the EXIT trap still emits an error.
# ============================================================
BRITIVE_ACTION="de-elevate"
BRITIVE_STATUS="error"
BRITIVE_CODE="UNEXPECTED"
BRITIVE_MESSAGE="Script terminated before reaching an outcome."
BRITIVE_USER=""
BRITIVE_HOST=""
BRITIVE_WARNINGS=""

json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | tr '\n\r\t' '   '
}

add_warning() {
    local w
    w="\"$(json_escape "$1")\""
    if [ -z "$BRITIVE_WARNINGS" ]; then
        BRITIVE_WARNINGS="$w"
    else
        BRITIVE_WARNINGS="${BRITIVE_WARNINGS},${w}"
    fi
}

emit_status() {
    printf 'BRITIVE_STATUS {"status":"%s","action":"%s","code":"%s","user":"%s","host":"%s","message":"%s","warnings":[%s]}\n' \
        "$BRITIVE_STATUS" \
        "$BRITIVE_ACTION" \
        "$BRITIVE_CODE" \
        "$(json_escape "$BRITIVE_USER")" \
        "$(json_escape "$BRITIVE_HOST")" \
        "$(json_escape "$BRITIVE_MESSAGE")" \
        "$BRITIVE_WARNINGS"
}
trap emit_status EXIT

fail() {
    BRITIVE_STATUS="error"
    BRITIVE_CODE="$1"
    BRITIVE_MESSAGE="$2"
    echo "ERROR: $2"
    exit 1
}

succeed() {
    BRITIVE_STATUS="success"
    BRITIVE_CODE="$1"
    BRITIVE_MESSAGE="$2"
}

# --- Configuration ---
TARGET_USER=""
while [ "$#" -gt 0 ]; do
    case "$1" in
      -Username) TARGET_USER="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
done

HOSTNAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)
BRITIVE_HOST="$HOSTNAME"
BRITIVE_USER="$TARGET_USER"

if [ -z "$TARGET_USER" ]; then
    echo 'Usage: runscript -CloudFile="<uploaded-name>" -CommandLine="-Username <account>"'
    fail "MISSING_PARAM" "No -Username supplied."
fi

if [ "$(id -u)" -ne 0 ]; then
    fail "NOT_PRIVILEGED" "Script must run as root. RTR runs as root by default."
fi

echo "Target user: ${TARGET_USER}@${HOSTNAME}"

# ============================================================
# Step 1: Check whether the account exists
#   A missing account is not fatal here. Revocation only has to prove the
#   account does not hold admin rights, and Step 3 verifies that directly
#   against the group. Missing account -> nothing to remove, verify still runs.
# ============================================================
USER_EXISTS=true
TARGET_UID=""
if id "$TARGET_USER" &>/dev/null; then
    TARGET_UID=$(id -u "$TARGET_USER")
    echo "User UID: $TARGET_UID"
else
    USER_EXISTS=false
    add_warning "user_not_found"
    echo "WARNING: User '$TARGET_USER' does not exist on this system."
    echo "         Nothing to remove; group membership will still be verified."
fi

# ============================================================
# Step 2: Remove user from admin group
# ============================================================
ALREADY_ADMIN=$(dseditgroup -o checkmember -m "$TARGET_USER" admin 2>&1 || true)
WAS_ADMIN=false

if echo "$ALREADY_ADMIN" | grep -q "yes"; then
    WAS_ADMIN=true
    if dseditgroup -o edit -d "$TARGET_USER" -t user admin 2>/dev/null; then
        echo "SUCCESS: Removed '$TARGET_USER' from the admin group."
    else
        fail "GROUP_REMOVE_FAILED" "Failed to remove '$TARGET_USER' from the admin group."
    fi
else
    echo "User '$TARGET_USER' is not currently in the admin group. No changes needed."
fi

# ============================================================
# Step 3: Verify removal
# ============================================================
VERIFY=$(dseditgroup -o checkmember -m "$TARGET_USER" admin 2>&1 || true)
if echo "$VERIFY" | grep -q "yes"; then
    fail "VERIFY_FAILED" "Verification failed — '$TARGET_USER' is still in the admin group."
else
    echo "VERIFIED: '$TARGET_USER' is no longer a member of the admin group."
fi

# The privilege change is now applied and verified. Everything below is
# best-effort notification: it can add warnings but never flips the outcome.
if [ "$WAS_ADMIN" = true ]; then
    succeed "OK" "'$TARGET_USER' no longer holds local admin rights on $HOSTNAME."
else
    succeed "NOT_MEMBER" "'$TARGET_USER' holds no admin rights on $HOSTNAME; nothing to revoke."
fi

# ============================================================
# Step 4: Detect active GUI session
# ============================================================
echo ""
echo "Locating user's GUI session..."

SESSION_ACTIVE=false

if [ "$USER_EXISTS" = false ]; then
    echo "Account does not exist; skipping session lookup and notification."
    echo ""
    echo "============================================================"
    echo "DONE (no such account). No admin rights are held on $HOSTNAME."
    echo "============================================================"
    exit 0
fi

# Check via 'who' (covers console login)
if who | grep -q "^${TARGET_USER}[[:space:]]"; then
    SESSION_ACTIVE=true
    echo "Found active login session for '$TARGET_USER' (via who)."
fi

# Fallback: check for a running Finder process (covers fast-user-switching)
if [ "$SESSION_ACTIVE" = false ] && pgrep -u "$TARGET_USER" -x Finder &>/dev/null; then
    SESSION_ACTIVE=true
    echo "Found Finder process for '$TARGET_USER' (GUI session active)."
fi

if [ "$SESSION_ACTIVE" = false ]; then
    add_warning "notify_no_session"
    echo "WARNING: No active GUI session detected for '$TARGET_USER'."
    echo "Admin group change is applied. Notification will be skipped."
    echo "The user's admin privileges have been revoked."
    echo ""
    echo "============================================================"
    echo "DONE (no active session). '$TARGET_USER' admin access removed."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Step 5: Push notification directly into the user's GUI session
#         launchctl asuser <uid> runs the command inside the user's
#         login session so osascript can reach the WindowServer.
# ============================================================
echo ""
echo "Pushing notification to user's session (UID $TARGET_UID)..."

# Fire the modal dialog into the user's session (waits for OK click)
if launchctl asuser "$TARGET_UID" sudo -u "$TARGET_USER" \
    /usr/bin/osascript -e "
display dialog \"Administrator Access Revoked\" & return & return & ¬
    \"Your local Administrator privileges have been removed.\" & return & return & ¬
    \"What this means:\" & return & ¬
    \"  • You can no longer install applications that require admin access.\" & return & ¬
    \"  • You cannot make system-level changes.\" & return & ¬
    \"  • Standard user access remains unaffected.\" & return & return & ¬
    \"No further action is needed.\" ¬
    buttons {\"OK - Got it\"} ¬
    default button \"OK - Got it\" ¬
    with title \"Elevated Access Revoked\" ¬
    with icon caution
" 2>/dev/null; then
    echo "SUCCESS: Notification dialog displayed and acknowledged by user."
else
    add_warning "notify_failed"
    echo "WARNING: osascript returned non-zero. The user may have dismissed"
    echo "         the dialog, or the session became inactive mid-run."
    echo "         Admin group removal was still applied successfully."
fi

# ============================================================
# Result
# ============================================================
echo ""
echo "============================================================"
echo "DONE."
echo "  User '$TARGET_USER' admin access has been removed on $HOSTNAME."
echo "  A pop-up notification was pushed to their active session."
echo "  No files were placed on the desktop."
echo "  No action was required from the user."
echo "============================================================"
exit 0
