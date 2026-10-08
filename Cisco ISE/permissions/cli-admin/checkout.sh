#!/usr/bin/env bash
# ============================================================
# Cisco ISE – CLI Admin Checkout (JIT)
# ============================================================
# Creates a temporary ISE *CLI* administrator (the ADE-OS shell
# account used over SSH / console, distinct from GUI admins) at
# checkout and removes it at checkin.
#
# ISE CLI:  configure terminal
#           username <name> password plain <pw> role admin|user
#           no username <name>
#
# Required env vars:
#   ISE_HOST              – ISE node hostname or IP (per node; CLI users are node-local)
#   ISE_CLI_ADMIN_USER    – Existing CLI admin the broker logs in as
#   ISE_CLI_ADMIN_PASSWORD– Its password (Britive Secrets Store)
#   BRITIVE_USER_EMAIL    – Requesting identity (Britive-injected); the local
#                           part becomes the CLI username, prefixed
#
# Optional env vars:
#   ISE_CLI_ROLE          – admin | user (default: admin)
#   ISE_JIT_PREFIX        – Username prefix (default: "brt-")
#   ISE_PASSWORD_LENGTH   – Generated password length (default: 20)
#   ISE_KNOWN_HOSTS       – known_hosts file holding the ISE host key
#   ISE_ACCEPT_HOST_KEY   – "true" to trust unknown keys on first connect (lab only)
#
# Stdout: one JSON line {"login","hostname","password","ssh_command"}
# Stderr: progress
# ============================================================
set -euo pipefail

: "${ISE_HOST:?ISE_HOST is not set.}"
: "${ISE_CLI_ADMIN_USER:?ISE_CLI_ADMIN_USER is not set.}"
: "${ISE_CLI_ADMIN_PASSWORD:?ISE_CLI_ADMIN_PASSWORD is not set.}"
: "${BRITIVE_USER_EMAIL:?BRITIVE_USER_EMAIL is not set.}"

export ISE_JIT_PREFIX="${ISE_JIT_PREFIX-brt-}"
ISE_TARGET_USER="${ISE_JIT_PREFIX}${BRITIVE_USER_EMAIL%%@*}"
export ISE_TARGET_USER
export ISE_CLI_ROLE="${ISE_CLI_ROLE:-admin}"
export ISE_KNOWN_HOSTS="${ISE_KNOWN_HOSTS:-}"
export ISE_ACCEPT_HOST_KEY="${ISE_ACCEPT_HOST_KEY:-false}"
ISE_PASSWORD_LENGTH="${ISE_PASSWORD_LENGTH:-20}"

case "${ISE_CLI_ROLE}" in admin|user) ;; *) echo "ERROR: ISE_CLI_ROLE must be admin or user" >&2; exit 1;; esac

# ISE enforces CLI password policy (mixed case, digit, no username); generate
# accordingly: letters + digits, then force one of each class.
_rand="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
ISE_TARGET_PASSWORD="A1a${_rand:0:$((ISE_PASSWORD_LENGTH - 3))}"
unset _rand
export ISE_TARGET_PASSWORD

command -v expect >/dev/null || { echo "ERROR: 'expect' is not installed." >&2; exit 1; }
command -v ssh    >/dev/null || { echo "ERROR: 'ssh' is not installed." >&2; exit 1; }

echo "Starting ISE CLI admin checkout on ${ISE_HOST} for ${BRITIVE_USER_EMAIL} -> ${ISE_TARGET_USER} (${ISE_CLI_ROLE})" >&2

expect -f - <<'EXPECT_SCRIPT'
set timeout 20
log_user 0
set host        $env(ISE_HOST)
set admin_user  $env(ISE_CLI_ADMIN_USER)
set admin_pass  $env(ISE_CLI_ADMIN_PASSWORD)
set target_user $env(ISE_TARGET_USER)
set target_pass $env(ISE_TARGET_PASSWORD)
set role        $env(ISE_CLI_ROLE)
set known_hosts $env(ISE_KNOWN_HOSTS)
set accept_key  $env(ISE_ACCEPT_HOST_KEY)
set prompt      {(^|[\r\n])[^\r\n]*[#] ?$}
set cfg_prompt  {\(config\)# ?$}

if {[string tolower $accept_key] eq "true"} {
    set hk [list -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null]
} elseif {$known_hosts ne ""} {
    set hk [list -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts]
} else {
    set hk [list -o StrictHostKeyChecking=yes]
}

spawn ssh {*}$hk -o ConnectTimeout=10 -l $admin_user $host
expect {
    -nocase -re {password:} { send "$admin_pass\r" }
    -re {Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|No .* host key is known} {
        puts stderr "  ERROR: Host key for $host is unknown or changed. Add it to ISE_KNOWN_HOSTS."
        exit 1
    }
    timeout { puts stderr "  ERROR: no password prompt from $host"; exit 1 }
    eof     { puts stderr "  ERROR: connection to $host closed"; exit 1 }
}
expect {
    -re $prompt {}
    -nocase -re {password:} { puts stderr "  ERROR: authentication failed for $admin_user"; exit 1 }
    timeout { puts stderr "  ERROR: no shell prompt from $host"; exit 1 }
}

# Pre-flight: refuse to touch an unprefixed existing account
send "show running-config | include ^username $target_user \r"
set exists 0
expect {
    -ex "\nusername $target_user " { set exists 1; exp_continue }
    -re $prompt {}
    timeout { puts stderr "  ERROR: timed out checking existing users"; exit 1 }
}
if {$exists} {
    if {$env(ISE_JIT_PREFIX) eq ""} {
        puts stderr "  ERROR: '$target_user' already exists and ISE_JIT_PREFIX is empty. Refusing."
        exit 1
    }
    puts stderr "  WARNING: '$target_user' already exists (leftover). Refreshing in place."
}

send "configure terminal\r"
expect { -re $cfg_prompt {} timeout { puts stderr "  ERROR: could not enter config mode"; exit 1 } }
send "username $target_user password plain $target_pass role $role\r"
expect {
    -re {% .*[\r\n]} { puts stderr "  ERROR: ISE rejected the username command: $expect_out(0,string)"; exit 1 }
    -re $cfg_prompt {}
    timeout { puts stderr "  ERROR: timed out after username command"; exit 1 }
}
send "end\r"
expect { -re $prompt {} timeout { puts stderr "  ERROR: timed out after end"; exit 1 } }

# Verify
send "show running-config | include ^username $target_user \r"
set verified 0
expect {
    -ex "\nusername $target_user " { set verified 1; exp_continue }
    -re $prompt {}
    timeout { puts stderr "  ERROR: timed out verifying"; exit 1 }
}
if {!$verified} { puts stderr "  ERROR: '$target_user' not present after creation"; exit 1 }
puts stderr "  Created CLI user '$target_user' with role $role on $host."
send "exit\r"
expect eof
EXPECT_SCRIPT

printf '{"login":"%s","hostname":"%s","password":"%s","ssh_command":"ssh %s@%s"}\n' \
    "${ISE_TARGET_USER}" "${ISE_HOST}" "${ISE_TARGET_PASSWORD}" "${ISE_TARGET_USER}" "${ISE_HOST}"
