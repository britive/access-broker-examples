# OpenLDAP User Group Management Scripts

## Scripts

### 1. **add_user_to_group.sh**

- **Purpose**: Adds an existing user to an OpenLDAP group.
- **Behavior**:
  - If the user ID is in email format (e.g., `user@example.com`), the script automatically removes the domain part and uses only the username (`user`).
  - Verifies that the user exists before adding them to the group.

### 2. **remove_user_from_group.sh**

- **Purpose**: Removes a user from an OpenLDAP group.
- **Behavior**:
  - Strips the email suffix from the user ID (e.g., `user@example.com` -> `user`).
  - Removes the user from the specified group.

---
