#!/usr/bin/env bash
# ============================================================
# Cisco ISE – CLI Admin Checkin (JIT)
# ============================================================
# Removes the temporary ISE CLI administrator created by checkout.sh.
# Idempotent; retries once on failure.
#
# Required env vars:
#   ISE_HOST, ISE_CLI_ADMIN_USER, ISE_CLI_ADMIN_PASSWORD, BRITIVE_USER_EMAIL
# Optional env vars:
#   ISE_JIT_PREFIX (default "brt-"), ISE_CHECKIN_RETRIES (default 1),
#   ISE_KNOWN_HOSTS, ISE_ACCEPT_HOST_KEY
#
# Stdout: nothing. Stderr: progress.
# ============================================================
set -euo pipefail

: "${ISE_HOST:?ISE_HOST is not set.}"
: "${ISE_CLI_ADMIN_USER:?ISE_CLI_ADMIN_USER is not set.}"
: "${ISE_CLI_ADMIN_PASSWORD:?ISE_CLI_ADMIN_PASSWORD is not set.}"
: "${BRITIVE_USER_EMAIL:?BRITIVE_USER_EMAIL is not set.}"

export ISE_JIT_PREFIX="${ISE_JIT_PREFIX-brt-}"
export ISE_TARGET_USER="${ISE_JIT_PREFIX}${BRITIVE_USER_EMAIL%%@*}"
export ISE_KNOWN_HOSTS="${ISE_KNOWN_HOSTS:-}"
export ISE_ACCEPT_HOST_KEY="${ISE_ACCEPT_HOST_KEY:-false}"
ISE_CHECKIN_RETRIES="${ISE_CHECKIN_RETRIES:-1}"

command -v expect >/dev/null || { echo "ERROR: 'expect' is not installed." >&2; exit 1; }

remove_user() {
expect -f - <<'EXPECT_SCRIPT'
set timeout 20
log_user 0
set host        $env(ISE_HOST)
set admin_user  $env(ISE_CLI_ADMIN_USER)
set admin_pass  $env(ISE_CLI_ADMIN_PASSWORD)
set target_user $env(ISE_TARGET_USER)
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
        puts stderr "  ERROR: Host key for $host is unknown or changed."; exit 1
    }
    timeout { puts stderr "  ERROR: no password prompt from $host"; exit 1 }
    eof     { puts stderr "  ERROR: connection to $host closed"; exit 1 }
}
expect {
    -re $prompt {}
    -nocase -re {password:} { puts stderr "  ERROR: authentication failed for $admin_user"; exit 1 }
    timeout { puts stderr "  ERROR: no shell prompt from $host"; exit 1 }
}
send "configure terminal\r"
expect { -re $cfg_prompt {} timeout { puts stderr "  ERROR: could not enter config mode"; exit 1 } }
send "no username $target_user\r"
expect {
    -nocase -re {\[confirm\]|continue\?|\(y/n\)} { send "y\r"; exp_continue }
    -re $cfg_prompt {}
    timeout { puts stderr "  ERROR: timed out after no username"; exit 1 }
}
send "end\r"
expect { -re $prompt {} timeout { puts stderr "  ERROR: timed out after end"; exit 1 } }
send "show running-config | include ^username $target_user \r"
set still 0
expect {
    -ex "\nusername $target_user " { set still 1; exp_continue }
    -re $prompt {}
    timeout { puts stderr "  ERROR: timed out verifying removal"; exit 1 }
}
if {$still} { puts stderr "  ERROR: '$target_user' still present after removal"; exit 1 }
puts stderr "  Removed CLI user '$target_user' from $host."
send "exit\r"
expect eof
EXPECT_SCRIPT
}

echo "Starting ISE CLI admin checkin on ${ISE_HOST}: remove ${ISE_TARGET_USER}" >&2
attempt=0
until remove_user; do
    attempt=$((attempt + 1))
    if (( attempt > ISE_CHECKIN_RETRIES )); then
        echo "ERROR: Checkin FAILED after ${attempt} attempt(s). Remove manually: 'no username ${ISE_TARGET_USER}' on ${ISE_HOST}." >&2
        exit 1
    fi
    echo "  attempt ${attempt} failed; retrying in 5s..." >&2
    sleep 5
done
