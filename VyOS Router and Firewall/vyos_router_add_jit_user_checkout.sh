#!/bin/bash

# =============================================================
# Just-In-Time (JIT) User Creation for VyOS Router and Firewall
# =============================================================
# This script creates a temporary user on a VyOS router with a randomly generated password.
# It uses an 'expect' script to automate the SSH session for setting up the new user.

# -----------------------
# Configuration Variables
# -----------------------

VYOS_HOST="1.2.3.4"                                                     # VyOS Router IP Address (Update as needed)
SERVICE_ACCOUNT="srv_account_name_example"                              # Default service account user for VyOS Router
SERVICE_ACCOUNT_PASSWORD="srv_account_password_example"                 # Default password for the service account

# Extract and sanitize the username from the provided email
JIT_USERNAME=${username}                        # Get the full email address Britive checkout process
JIT_USERNAME="${JIT_USERNAME%%@*}"              # Extract everything before '@'
JIT_USERNAME="${JIT_USERNAME//[^a-zA-Z0-9]/}"   # Remove any non-alphanumeric characters

# -----------------------
# Generate Random Password
# -----------------------

# Generate a 16-character random password consisting of letters and numbers
JIT_PASSWORD=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')

# -----------------------
# Install Expect (if needed)
# -----------------------

# 'expect' is required to handle interactive SSH sessions.
# Check if 'expect' is installed, and install it if missing (for Debian-based systems).

if ! command -v expect &> /dev/null; then
    echo "Expect not found, installing..."
    sudo apt update && sudo apt install -y expect
fi

# -----------------------
# Automate SSH Session Using Expect
# -----------------------

# The following 'expect' script automates SSH interactions for:
# 1. Logging into the VyOS router.
# 2. Entering configuration mode.
# 3. Creating a new user with the generated password.
# 4. Committing and saving the changes.
# 5. Exiting the session.

expect <<EOF
log_user 0 ; # Turn off screen output
spawn -noecho ssh $SERVICE_ACCOUNT@$VYOS_HOST

# Authenticate using the service account password
expect "password:"
send "$SERVICE_ACCOUNT_PASSWORD\r"

# Enter VyOS configuration mode
expect "$ "
send "configure\r"

# Create the new user with the generated password
expect "#"
send "set system login user $JIT_USERNAME authentication plaintext-password $JIT_PASSWORD\r"

# Apply the changes
expect "#"
send "commit\r"

# Save the configuration
expect "#"
send "save\r"

# Exit configuration mode
expect "#"
send "exit\r"

# Logout from VyOS
expect "$ "
send "exit\r"

EOF

# -----------------------
# Output Login Credentials
# -----------------------

echo "JIT password processed successfully."
echo "Your JIT random password is: $JIT_PASSWORD"
echo "Use the following command to log in:"
echo "ssh $JIT_USERNAME@$VYOS_HOST"
