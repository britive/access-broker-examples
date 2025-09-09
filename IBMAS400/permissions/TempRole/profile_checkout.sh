#!/bin/bash

# ==============================
# Environment Variables (validated inline)
# ==============================
AS400_HOST="${AS400_HOST:?AS400_HOST not set or empty}"
AS400_USER="${AS400_USER:?AS400_USER not set or empty}"
AS400_KEY="${AS400_KEY:?AS400_KEY not set or empty}"
TARGET_USER="${TARGET_USER:?TARGET_USER not set or empty}"

# Example AS400 function/command
AS400_COMMAND="CALL MYLIB/MYCUSTOMFUNC PARM('$TARGET_USER')"

# ==============================
# Execution
# ==============================
echo "Connecting to AS400: $AS400_HOST as $AS400_USER to run function for $TARGET_USER"

ssh -i "$AS400_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$AS400_USER@$AS400_HOST" \
    "$AS400_COMMAND"

STATUS=$?

if [ $STATUS -eq 0 ]; then
    echo "✅ Function executed successfully for $TARGET_USER"
else
    echo "❌ Failed to execute function. Exit code: $STATUS"
fi

exit $STATUS
