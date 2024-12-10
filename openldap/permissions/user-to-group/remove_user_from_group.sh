#!/bin/bash

# Remove user from OpenLDAP group

# Configuration
LDAP_SERVER="ldap://localhost"                # LDAP server URL
BASE_DN="dc=example,dc=com"                   # Base DN
BIND_DN="cn=admin,dc=example,dc=com"          # LDAP Bind DN
BIND_PASSWORD="PasswordHERE"                # LDAP admin password

USER_ID="$USER"                                 # User UID (username) in an email format can be passed here upon checkout
GROUP_NAME="$GROUP"                             # LDAP group name is passed here via checkout. Profile is configured with GROUP name


# Strip email suffix if present (e.g., user@example.com -> user)
USER_UID=$(echo "$USER_ID" | sed 's/@.*//')

# Remove user from group
echo "Removing user $USER_UID from group $GROUP_NAME..."

GROUP_LDIF="/tmp/remove_user_from_group.ldif"
cat > "$GROUP_LDIF" <<EOF
dn: cn=$GROUP_NAME,ou=groups,$BASE_DN
changetype: modify
delete: memberUid
memberUid: $USER_UID
EOF

ldapmodify -x -H "$LDAP_SERVER" -D "$BIND_DN" -w "$BIND_PASSWORD" -f "$GROUP_LDIF"

if [ $? -ne 0 ]; then
    echo "Error: Failed to remove user $USER_UID from group $GROUP_NAME"
    exit 1
fi

echo "User $USER_UID removed from group $GROUP_NAME successfully."