#!/bin/bash
# ============================================================
# SYNOPSIS
#     CrowdStrike Falcon RTR script to add a user to the local admin
#     group and automatically display a notification in the user's GUI session.
# DESCRIPTION
#     Adds a user to the macOS admin group, verifies membership, then
#     immediately pops up a dialog in the user's active GUI session —
#     no launcher files, no manual action required from the user.
# NOTES
#     Platform:       macOS (Darwin)
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
# Step 2: Add user to admin group
# ============================================================
ALREADY_ADMIN=$(dseditgroup -o checkmember -m "$TARGET_USER" admin 2>&1 || true)

if echo "$ALREADY_ADMIN" | grep -q "yes"; then
    echo "User '$TARGET_USER' is already in the admin group."
else
    if dseditgroup -o edit -a "$TARGET_USER" -t user admin 2>/dev/null; then
        echo "SUCCESS: Added '$TARGET_USER' to the admin group."
    else
        echo "ERROR: Failed to add '$TARGET_USER' to the admin group."
        echo "This script must run as root (RTR runs as root by default)."
        exit 1
    fi
fi

# ============================================================
# Step 3: Verify membership
# ============================================================
VERIFY=$(dseditgroup -o checkmember -m "$TARGET_USER" admin 2>&1 || true)
if echo "$VERIFY" | grep -q "yes"; then
    echo "VERIFIED: '$TARGET_USER' is a member of the admin group."
else
    echo "ERROR: Verification failed — user not found in admin group."
    exit 1
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
    echo "The user will have admin privileges the next time they log in."
    echo ""
    echo "============================================================"
    echo "DONE (no active session). '$TARGET_USER' is now an admin."
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
display dialog \"Administrator Access Granted\" & return & return & ¬
    \"Your Mac account has been granted local Administrator privileges.\" & return & return & ¬
    \"What this means:\" & return & ¬
    \"  • You can now install applications.\" & return & ¬
    \"  • You can run software that requires elevated permissions.\" & return & ¬
    \"  • A password prompt may still appear for sensitive operations.\" & return & return & ¬
    \"No further action is needed.\" ¬
    buttons {\"OK - Got it\"} ¬
    default button \"OK - Got it\" ¬
    with title \"Elevated Access Notification\" ¬
    with icon caution
" 2>/dev/null; then
    echo "SUCCESS: Notification dialog displayed and acknowledged by user."
else
    echo "WARNING: osascript returned non-zero. The user may have dismissed"
    echo "         the dialog, or the session became inactive mid-run."
    echo "         Admin group change was still applied successfully."
fi

# ============================================================
# Result
# ============================================================
echo ""
echo "============================================================"
echo "DONE."
echo "  User '$TARGET_USER' is now a local Administrator on $HOSTNAME."
echo "  A pop-up notification was pushed to their active session."
echo "  No files were placed on the desktop."
echo "  No action was required from the user."
echo "============================================================"
exit 0