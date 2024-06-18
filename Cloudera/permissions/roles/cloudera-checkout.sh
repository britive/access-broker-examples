#!/bin/bash

USER="${user}"
ROLE="${role}"

echo $ROLE
echo $USER

export USER_ID=$(cdp iam list-users | jq -r '.users[] | select(.email=="'${USER}'") | .userId')
echo $USER_ID

cdp iam assign-user-role --user "${USER_ID}" --role "${ROLE}"
