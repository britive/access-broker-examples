#!/bin/bash

USER="${user}"
GROUP="${group}"

echo $USER
echo $GROUP

export USER_ID=$(cdp iam list-users | jq -r '.users[] | select(.email=="'${USER}'") | .userId')
echo $USER_ID

cdp iam remove-user-from-group --user-id "${USER_ID}" --group-name "${GROUP}"
