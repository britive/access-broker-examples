#!/bin/bash
# ============================================================
# SYNOPSIS
#     CrowdStrike Falcon RTR script to remove a user from the local admin
#     group and automatically display a notification in the user's GUI session.

# DESCRIPTION
#     Accepts a macOS username as a parameter, removes it from the admin group,
#     verifies removal, then immediately pops up a dialog in the user's
#     active GUI session — no launcher files, no manual action required.
# NOTES
#     Requires:       RTR Admin or RTR Active Responder role with runscript permission
#     Impact:         A notification dialog appears on the user's screen automatically.
# ============================================================

set -e

# --- Configuration ---
 while [ "$#" -gt 0 ]; do
    case "$1" in
      -Username) TARGET_USER="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

HOSTNAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: No -Username supplied."
    echo 'Usage: runscript -CloudFile="Mac-De-elevateUserAdminAccess" -CommandLine="-Username <account>"'
    exit 1
fi

echo "Target user: ${TARGET_USER}@${HOSTNAME}"

# ============================================================
# Step 1: Verify user exists
# ============================================================
if ! id "$TARGET_USER" &>/dev/null; then
    echo "ERROR: User '$TARGET_USER' does not exist on this system."
    exit 1
fi

TARGET_UID=$(id -u "$TARGET_USER")
echo "User UID: $TARGET_UID"

# ============================================================
# Step 2: Remove user from admin group
# ============================================================
ALREADY_ADMIN=$(dseditgroup -o checkmember -m "$TARGET_USER" admin 2>&1 || true)

if echo "$ALREADY_ADMIN" | grep -q "yes"; then
    if dseditgroup -o edit -d "$TARGET_USER" -t user admin 2>/dev/null; then
        echo "SUCCESS: Removed '$TARGET_USER' from the admin group."
    else
        echo "ERROR: Failed to remove '$TARGET_USER' from the admin group."
        echo "This script must run as root (RTR runs as root by default)."
        exit 1
    fi
else
    echo "User '$TARGET_USER' is not currently in the admin group. No changes needed."
fi

# ============================================================
# Step 3: Verify removal
# ============================================================
VERIFY=$(dseditgroup -o checkmember -m "$TARGET_USER" admin 2>&1 || true)
if echo "$VERIFY" | grep -q "yes"; then
    echo "ERROR: Verification failed — user is still in the admin group."
    exit 1
else
    echo "VERIFIED: '$TARGET_USER' is no longer a member of the admin group."
fi

# ============================================================
# Step 4: Detect active GUI session
# ============================================================
echo ""
echo "Locating user's GUI session..."

SESSION_ACTIVE=false

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
