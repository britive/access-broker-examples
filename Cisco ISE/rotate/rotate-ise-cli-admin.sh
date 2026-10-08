#!/usr/bin/env bash
# ============================================================
# Cisco ISE – Rotate a CLI admin password
# ============================================================
# Rotates the password of an existing ISE CLI (ADE-OS) account,
# preserving its role. Wire as both checkout and checkin script
# for a break-glass profile: checkout returns the new secret to
# the user, checkin rotates again and returns it to the broker.
#
# ISE CLI:  configure terminal
#           username <name> password plain <new> role <existing-role>
#
# Required env vars:
#   ISE_HOST, ISE_CLI_ADMIN_USER, ISE_CLI_ADMIN_PASSWORD
#   ISE_TARGET_USER        – CLI account to rotate (e.g. "admin"). May be the
#                            same as ISE_CLI_ADMIN_USER (self-rotation).
# Optional env vars:
#   ISE_NEW_PASSWORD       – Supply only if another system owns the value
#   ISE_PASSWORD_LENGTH    – Generated length (default 20)
#   ISE_KNOWN_HOSTS, ISE_ACCEPT_HOST_KEY
#
# Stdout: one JSON line {"login","hostname","password","role"}
# ============================================================
set -euo pipefail
: "${ISE_HOST:?}"; : "${ISE_CLI_ADMIN_USER:?}"; : "${ISE_CLI_ADMIN_PASSWORD:?}"; : "${ISE_TARGET_USER:?ISE_TARGET_USER is not set.}"
export ISE_TARGET_USER
export ISE_KNOWN_HOSTS="${ISE_KNOWN_HOSTS:-}"
export ISE_ACCEPT_HOST_KEY="${ISE_ACCEPT_HOST_KEY:-false}"
ISE_PASSWORD_LENGTH="${ISE_PASSWORD_LENGTH:-20}"
if [[ -z "${ISE_NEW_PASSWORD:-}" ]]; then
    _rand="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
    ISE_NEW_PASSWORD="A1a${_rand:0:$((ISE_PASSWORD_LENGTH - 3))}"; unset _rand
fi
export ISE_NEW_PASSWORD
export ISE_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ise-ssh-common.exp"
command -v expect >/dev/null || { echo "ERROR: 'expect' is not installed." >&2; exit 1; }
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

echo "Rotating ISE CLI account '${ISE_TARGET_USER}' on ${ISE_HOST}" >&2

role="$(expect -f - <<'EXPECT_SCRIPT'
source $env(ISE_COMMON)
set target_user $env(ISE_TARGET_USER)
set new_pass    $env(ISE_NEW_PASSWORD)

# Discover the current role so it is preserved (role is mandatory on the username command)
send "show running-config | include ^username $target_user \r"
set role ""
expect {
    -re "\nusername $target_user \[^\r\n\]* role (admin|user)" { set role $expect_out(1,string); exp_continue }
    -re $prompt {}
    timeout { puts stderr "  ERROR: timed out reading current role"; exit 1 }
}
if {$role eq ""} { puts stderr "  ERROR: CLI account '$target_user' not found on $host (rotation never creates accounts)"; exit 1 }

send "configure terminal\r"
expect { -re $cfg_prompt {} timeout { puts stderr "  ERROR: could not enter config mode"; exit 1 } }
send "username $target_user password plain $new_pass role $role\r"
expect {
    -re {% .*[\r\n]} { puts stderr "  ERROR: ISE rejected the username command: $expect_out(0,string)"; exit 1 }
    -re $cfg_prompt {}
    timeout { puts stderr "  ERROR: timed out after username command"; exit 1 }
}
send "end\r"
expect { -re $prompt {} timeout { puts stderr "  ERROR: timed out after end"; exit 1 } }
puts stderr "  Rotated '$target_user' (role $role) on $host."
send "exit\r"
expect eof
puts $role
EXPECT_SCRIPT
)" || exit 1
role="$(printf '%s' "$role" | tail -n1 | tr -d '\r')"

printf '{"login":"%s","hostname":"%s","password":"%s","role":"%s"}\n' \
    "$(json_escape "${ISE_TARGET_USER}")" "$(json_escape "${ISE_HOST}")" "$(json_escape "${ISE_NEW_PASSWORD}")" "${role}"
