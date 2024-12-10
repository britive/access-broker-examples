#!/bin/bash

# Add user to OpenLDAP group

# Configuration
LDAP_SERVER="ldap://localhost"                # LDAP server URL
BASE_DN="dc=example,dc=com"                   # Base DN
BIND_DN="cn=admin,dc=example,dc=com"          # LDAP Bind DN
BIND_PASSWORD="PasswordHERE"                # LDAP admin password

USER_ID="$USER"                                 # User UID (username) in an email format can be passed here upon checkout
GROUP_NAME="$GROUP"                             # LDAP group name is passed here via checkout. Profile is configured with GROUP name

# Strip email suffix if present (e.g., user@example.com -> user)
USER_UID=$(echo "$USER_ID" | sed 's/@.*//')

# Check if user exists
echo "Checking if user $USER_UID exists..."
USER_EXISTS=$(ldapsearch -x -H "$LDAP_SERVER" -D "$BIND_DN" -w "$BIND_PASSWORD" \
    -b "ou=users,$BASE_DN" "(uid=$USER_UID)" | grep -c "dn:")

if [ "$USER_EXISTS" -eq 0 ]; then
    echo "Error: User $USER_UID does not exist. Cannot add to group."
    exit 1
fi
echo "User $USER_UID exists."

# Add user to group
echo "Adding user $USER_UID to group $GROUP_NAME..."

GROUP_LDIF="/tmp/add_user_to_group.ldif"
cat > "$GROUP_LDIF" <<EOF
dn: cn=$GROUP_NAME,ou=groups,$BASE_DN
changetype: modify
add: memberUid
memberUid: $USER_UID
EOF

ldapmodify -x -H "$LDAP_SERVER" -D "$BIND_DN" -w "$BIND_PASSWORD" -f "$GROUP_LDIF"

if [ $? -ne 0 ]; then
    echo "Error: Failed to add user $USER_UID to group $GROUP_NAME"
    exit 1
fi

echo "User $USER_UID added to group $GROUP_NAME successfully."
