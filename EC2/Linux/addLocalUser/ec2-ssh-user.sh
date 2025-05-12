#!/bin/bash

ACTION=$BRITIVE_ACTION  # checkout or checkin sent from the platform
INSTANCE=$INSTANCE  # instance name sent from the platform
SUDO=${BRITIVE_SUDO:-"0"} # Sudo option sent from the platform
USER=$BRITIVE_USER_EMAIL  # user email sent from the platform

# Trim to get just the username before the @
USER_EMAIL=${USER:-"test@example.com"}
USERNAME="${USER_EMAIL%%@*}"
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"

USER=${USERNAME}
GROUP=${USERNAME}  # Default behavior is set to use username as group name

if [ "$ACTION" = "checkout" ]; then
  echo "Adding user $USER to instance $INSTANCE"
  aws ssm send-command \
  --document-name "addSSHKey" \
  --targets "Key=InstanceIds,Values=$INSTANCE" \
  --parameters "username=[\"$USERNAME\"],group=[\"$GROUP\"],userEmail=[\"$USER_EMAIL\"],sudo=[\"$SUDO\"]" \
  --region "us-west-2"
else
  echo "Removing user $USER from instance $INSTANCE"
  aws ssm send-command \
  --document-name "removeSSHKey" \
  --targets "Key=InstanceIds,Values=$INSTANCE" \
  --parameters "username=[\"$USERNAME\"],group=[\"$GROUP\"],userEmail=[\"$USER_EMAIL\"]" \
  --region "us-west-2"
fi