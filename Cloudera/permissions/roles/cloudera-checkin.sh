#!/bin/bash

USER=${user}
ROLE=${role}

echo $ROLE

export USER_ID=$(cdp iam list-users | jq -r '.users[] | select(.email=="'${USER}'") | .userId')
echo $USER_ID

cdp iam unassign-user-role --user "${USER_ID}" --role "${ROLE}"

