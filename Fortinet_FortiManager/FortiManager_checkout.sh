#!/bin/bash

fmg_host="<FortiManager IP Address>"
fmg_admin_user="FortiManager_Svc_Account"  # can be pulled from ENV variable or vault
fmg_admin_password="<Password>"            # can be pulled from ENV variable or vault
jit_password=""                            # This password is not used anywhere. Just for init purpose

# Extract and sanitize the username from the provided email

jit_ProfileID=${ProfileID}
jit_username=${username}                        # Get the full email address Britive checkout process
jit_username="${jit_username%%@*}"              # Extract everything before '@'
jit_username="${jit_username//[^a-zA-Z0-9]/}"   # Remove any non-alphanumeric characters


# -----------------------
# Generate Random Password
# -----------------------

# Generate a 16-character random password consisting of letters and numbers
jit_password=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')

expect <<EOF
set timeout 20
log_user 0 ; # Turn off screen output

spawn -noecho ssh $fmg_admin_user@$fmg_host
expect "Password:"
send "$fmg_admin_password\r"

expect "FortiManager-shahzad # "

puts "Successfully received JIT user information about $username from Britive tenant."

send "config system admin user\r"
expect "# "

send "edit $jit_username\r"
expect "($jit_username)# "

send "set password $jit_password\r"
expect "# "

send "set profileid $jit_ProfileID\r"
expect "($jit_username)# "

send "next\r"
expect "# "

send "end\r"
expect "#"

send "exit\r"
expect eof
EOF

echo "JIT user $jit_username configured successfully with 'FortiManager $jit_ProfileID' profile."
echo "Run ssh $jit_username@$fmg_host command with $jit_password password to login"
