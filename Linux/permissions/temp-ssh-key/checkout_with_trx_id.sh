#!/bin/bash

USER_EMAIL=${BRITIVE_USER_EMAIL:-"test@example.com"}
USERNAME="${USER_EMAIL%%@*}"
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"

USER=${USERNAME}
GROUP=${USERNAME}

SUDO=${BRITIVE_SUDO:-"0"}
TRX=${TRX:-"default-trx-id"}

useradd -m ${USER} 2>/dev/null

SSH_PATH=/${BRITIVE_HOME_ROOT:-"home"}/${USER}/.ssh

finish () {
  rm -f $SSH_PATH/britive-id_rsa*
  exit $1
}

if ! test -d $SSH_PATH; then
  mkdir -p $SSH_PATH || finish 1
  chmod 700 $SSH_PATH || finish 1
  chown $USER:$GROUP $SSH_PATH || finish 1
fi

# Generate keypair
ssh-keygen -q -N '' -t rsa -C $USER_EMAIL -f $SSH_PATH/britive-id_rsa || finish 1

# Append TRX marker to the generated public key
PUB_KEY_CONTENT="$(cat $SSH_PATH/britive-id_rsa.pub) trx-id=${TRX}"
echo "$PUB_KEY_CONTENT" > $SSH_PATH/britive-id_rsa.pub

# Merge into authorized_keys, avoiding duplicates
mapfile -t contents < <(cat $SSH_PATH/authorized_keys 2>/dev/null | sort -u)
mapfile -t -O "${#contents[@]}" contents < <(cat $SSH_PATH/britive-id_rsa.pub 2>/dev/null)
printf "%s\n" "${contents[@]}" > $SSH_PATH/authorized_keys

chmod 600 $SSH_PATH/authorized_keys || finish 1
chown $USER:$GROUP $SSH_PATH/authorized_keys || finish 1

# Optional sudo
if [ "$SUDO" != "0" ]; then
  echo "${USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER} || finish 1
  chmod 440 /etc/sudoers.d/${USER} || finish 1
fi

# Output the private key as PEM format
cat $SSH_PATH/britive-id_rsa || finish 1

finish 0
