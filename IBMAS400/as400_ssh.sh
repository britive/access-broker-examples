
#!/bin/bash

HOST="$AS400_HOST"
ADMIN_USER="$AS400_ADMIN_USER"
NEW_USER="$AS400_NEW_USER"
USER_DESC="$AS400_NEW_USER_DESC"
ACTION="$AS400_ACTION"

generate_password() {
    tr -dc 'A-Za-z0-9!@#$%^&*()' </dev/urandom | head -c 12
}

if [ "$ACTION" == "checkout" ]; then
    NEW_PASS=$(generate_password)
    echo "Generated password for $NEW_USER: $NEW_PASS"
    ssh $ADMIN_USER@$HOST "CRTUSRPRF USRPRF($NEW_USER) PASSWORD($NEW_PASS) TEXT('$USER_DESC')"

elif [ "$ACTION" == "checkin" ]; then
    ssh $ADMIN_USER@$HOST "DLTUSRPRF USRPRF($NEW_USER) OWNOBJOPT(*DLT)"

else
    echo "Invalid action. Use 'create' or 'remove'."
    exit 1
fi
