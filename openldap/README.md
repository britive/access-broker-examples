
![openldap!](openldap.png "OpenLDAP")

# OpenLDAP User Group Management Scripts

## Overview

This project provides two Bash scripts for managing **OpenLDAP** user group memberships on a Linux machine via Britive broker technology. These scripts allow administrators to:

1. **Add a user to an OpenLDAP group** (ignoring any email suffix if present).
2. **Remove a user from an OpenLDAP group** (also ignoring email suffixes).

The scripts assume an existing OpenLDAP server and use standard LDAP utilities like `ldapsearch`, `ldapmodify`, and `ldapadd`.

## Prerequisites

1. **Operating System**: Linux (Tested on Ubuntu).
2. **Tools**: Ensure that the following LDAP utilities are installed:

   ```bash
   sudo apt-get update
   sudo apt-get install ldap-utils


## LDAP Configuration

Update the following variables in the scripts to match your OpenLDAP server configuration:

* `LDAP_SERVER`: LDAP server URL (e.g., `ldap://localhost`).
* `BASE_DN`: Base Distinguished Name (e.g., `dc=example,dc=com`).
* `BIND_DN`: Bind DN for authentication (e.g., `cn=admin,dc=example,dc=com`).
* `BIND_PASSWORD`: Password for the Bind DN.

**LDAP Structure**:

* Users are stored in `ou=users`.
* Groups are stored in `ou=groups`.
* Groups use the `posixGroup` objectClass.

## Error Handling

1. If the specified user does not exist, the script will print an error and exit.
2. If the group modification fails (e.g., group does not exist), the script will print an error message.
3. The scripts check for missing arguments and provide usage instructions.

## Security Notes

1. Avoid hardcoding passwords for production use. Use environment variables or a secrets management tool.
2. Restrict permissions on the scripts to prevent unauthorized access:

    ```bash
    chmod 700 add_user_to_group.sh remove_user_from_group.sh

## Future Improvements

1. Add support for user creation if the user does not exist.
2. Implement LDAP over SSL/TLS (LDAPS).
3. Enhance error handling with more detailed LDAP search results.
