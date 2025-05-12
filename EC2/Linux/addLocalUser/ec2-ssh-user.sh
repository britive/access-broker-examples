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
  echo "Generating SSH key pair for $USERNAME for instance: $INSTANCE"
  KEY_DIR=$(mktemp -d)
  KEY_PATH="$KEY_DIR/britive-id_rsa"

  ssh-keygen -q -N "" -t rsa -f "$KEY_PATH"
  PUB_KEY=$(cat "$KEY_PATH.pub")

  echo "Sending public key to EC2 via SSM"
  COMMAND_ID=$(aws ssm send-command \
    --document-name "addSSHKey" \
    --targets "Key=InstanceIds,Values=$INSTANCE" \
    --parameters "username=[\"$USERNAME\"],group=[\"$GROUP\"],sshPublicKey=[\"$PUB_KEY\"],sudo=[\"$SUDO\"],userEmail=[\"$USER_EMAIL\"]" \
    --region "us-west-2" \
    --query "Command.CommandId" \
    --output text)

  if [ -z "$COMMAND_ID" ]; then
    echo "Failed to send command"
    exit 1
  fi

  echo "Waiting for SSM command ($COMMAND_ID) to complete..."

  while true; do
    STATUS=$(aws ssm list-command-invocations \
      --command-id "$COMMAND_ID" \
      --details \
      --region "us-west-2" \
      --query "CommandInvocations[0].Status" \
      --output text)

    if [[ "$STATUS" == "Success" ]]; then
      echo "Command completed successfully."
      break
    elif [[ "$STATUS" == "Failed" || "$STATUS" == "Cancelled" || "$STATUS" == "TimedOut" ]]; then
      echo "Command failed with status: $STATUS"
      exit 1
    else
      sleep 2
    fi
  done

  cat "$KEY_PATH"
  
else
  echo "Removing user $USER from instance $INSTANCE"
  aws ssm send-command \
  --document-name "removeSSHKey" \
  --targets "Key=InstanceIds,Values=$INSTANCE" \
  --parameters "username=[\"$USERNAME\"]" \
  --region "us-west-2"
fi