#!/bin/bash

# =================================================================
# Just-In-Time (JIT) User Deletion from VyOS created by Shahzad Ali
# =================================================================

# -----------------------
# Configuration Variables
# -----------------------

VYOS_HOST="1.2.3.4"                                           # VyOS Router IP
SERVICE_ACCOUNT="srv_account_name_example"                    # VyOS service account username
SERVICE_ACCOUNT_PASSWORD="srv_account_name_password"          # VyOS service account password

# Sanitize and extract the username from email-style input
JIT_USERNAME=${username}                       # Original email address received from Britive profile checkin process
JIT_USERNAME="${JIT_USERNAME%%@*}"             # Extract username before '@'
JIT_USERNAME="${JIT_USERNAME//[^a-zA-Z0-9]/}"  # Remove non-alphanumeric characters

echo "Command-Line User: $JIT_USERNAME"

# -----------------------
# Expect Script to Delete User
# -----------------------

# Automates the SSH session and deletes the specified user from VyOS
expect <<EOF
log_user 0 ; #Turn off screen output
spawn -noecho ssh $SERVICE_ACCOUNT@$VYOS_HOST

# Login prompt
expect "password:"
send "$SERVICE_ACCOUNT_PASSWORD\r"

# Enter configuration mode
expect "$ "
send "configure\r"

# Wait for config prompt
expect "#"
send "delete system login user $JIT_USERNAME\r"

# Commit the changes
expect "#"
send "commit\r"

# Save the configuration
expect "#"
send "save\r"

# Exit configuration mode
expect "#"
send "exit\r"

# Logout of VyOS
expect "$ "
send "exit\r"
EOF

# -----------------------
# Confirmation Output
# -----------------------

echo "Britive Check-in profile executed successfully"
echo "User '$JIT_USERNAME' has been removed from the VyOS router config"
echo "There is no standing user or lingering permission left on the router"
