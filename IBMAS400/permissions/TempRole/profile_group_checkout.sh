#!/bin/bash

# ==============================
# Environment Variables (validated inline)
# ==============================
AS400_HOST="${AS400_HOST:?AS400_HOST not set or empty}"
AS400_USER="${AS400_USER:?AS400_USER not set or empty}"
AS400_KEY="${AS400_KEY:?AS400_KEY not set or empty}"
TARGET_USER="${TARGET_USER:?TARGET_USER not set or empty}"
TARGET_GROUP="${TARGET_GROUP:?TARGET_GROUP not set or empty}"
ACTION="${ACTION:?ACTION not set (use add or remove)}"

# ==============================
# Build AS400 Command
# ==============================
case "$ACTION" in
  add)
    # Add user to a group (primary group example)
    AS400_COMMAND="CHGUSRPRF USRPRF($TARGET_USER) GRPPRF($TARGET_GROUP)"
    ;;
  remove)
    # Remove user from primary group (set to *NONE)
    AS400_COMMAND="CHGUSRPRF USRPRF($TARGET_USER) GRPPRF(*NONE)"
    ;;
  *)
    echo "Invalid ACTION: $ACTION (use add or remove)"
    exit 1
    ;;
esac

# ==============================
# Execution
# ==============================
echo "Connecting to AS400: $AS400_HOST as $AS400_USER to $ACTION $TARGET_USER in group $TARGET_GROUP"

ssh -i "$AS400_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$AS400_USER@$AS400_HOST" \
    "system \"$AS400_COMMAND\""

STATUS=$?

if [ $STATUS -eq 0 ]; then
    echo "Successfully executed group $ACTION for $TARGET_USER"
else
    echo "Failed to modify group membership. Exit code: $STATUS"
fi

exit $STATUS
