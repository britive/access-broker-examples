#!/bin/bash

fmg_host="<FortiManager ip address>"
fmg_admin_user="FortiManager_Svc_Account"
fmg_admin_password="<Password>"
jit_username=${username}

jit_username="${jit_username%%@*}"
jit_username="${jit_username//[^a-zA-Z0-9]/}"

timestamp=$(date +"%Y%m%d-%H%M%S")
log_file="fortimanager_checkin_${jit_username}_${timestamp}.log"

# --- Begin single Expect session ---
expect <<EOF | tee "$log_file"
set timeout 30
log_user 1

spawn ssh $fmg_admin_user@$fmg_host
expect "Password:"
send "$fmg_admin_password\r"
expect "FortiManager-shahzad # "

puts "=== [exec date]  ==="
puts "Logged in to FortiManager. Checking for active sessions for user '$jit_username'."

# Get the session list
send "diagnose system admin-session list\r"
expect "FortiManager-shahzad # "
set session_output \$expect_out(buffer)

# Parse the session ID for the target username
set session_id ""
foreach line [split \$session_output "\n"] {
    if {[string match "*session_id:*" \$line]} {
        regexp {session_id:\s+([0-9]+)} \$line -> id
    }
    if {[string match "*username: $jit_username*" \$line]} {
        set session_id \$id
        break
    }
}

if { \$session_id ne "" } {
    puts "Active session found for '$jit_username' with session_id \$session_id. Killing session..."
    send "diagnose system admin-session kill \$session_id\r"
    expect "FortiManager-shahzad # "
} else {
    puts "No active session found for '$jit_username'."
}

puts "Deleting user '$jit_username'..."
send "config system admin user\r"
expect "(user)#"
send "delete $jit_username\r"
expect "(user)#"
send "end\r"
expect "FortiManager-shahzad # "

send "exit\r"
expect eof
EOF

echo "Check-in complete. Log saved to: $log_file"
