#!/bin/bash

USER_EMAIL=${BRITIVE_USER_EMAIL:-"test@example.com"}
USERNAME="${USER_EMAIL%%@*}"
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"
KILL_SESSION=${KILL_SESSION:-"0"}

USER=${USERNAME}


SSH_PATH=/${BRITIVE_HOME_ROOT:-"home"}/${USER}/.ssh

finish () {
  exit $1
}

if test -d $SSH_PATH; then
  mapfile -t contents < <(cat $SSH_PATH/authorized_keys 2>/dev/null | grep -v "${USER_EMAIL}")

  if (( ${#contents[@]} > 0 )); then
    printf "%s\n" "${contents[@]}" > $SSH_PATH/authorized_keys || finish 1

    chmod 600 $SSH_PATH/authorized_keys || finish 1
  else
    rm -f $SSH_PATH/authorized_keys || finish 1
  fi
fi

if test -f /etc/sudoers.d/${USER}; then
  rm -f /etc/sudoers.d/${USER} > /dev/null 2>&1
fi

# Optionally kill active SSH sessions for this user
if [[ "${KILL_SESSION}" == "1" ]]; then
  echo "Killing SSH sessions for ${USER}"
  pkill -u "${USER}" sshd || true
fi

finish 0