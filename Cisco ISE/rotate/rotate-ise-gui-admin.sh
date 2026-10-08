#!/usr/bin/env bash
# ============================================================
# Cisco ISE – Rotate a GUI (admin portal) admin password
# ============================================================
# Resets the password of an ISE *GUI* administrator (internal admin
# user such as the built-in "admin") from the CLI:
#
#   application reset-passwd ise <gui-admin>
#   Enter new password: ...
#   Confirm new password: ...
#
# This is the only way to rotate the built-in GUI admin without an
# existing GUI session, and it works regardless of ISE version. Wire
# as both checkout and checkin script for a break-glass profile.
#
# Required env vars:
#   ISE_HOST, ISE_CLI_ADMIN_USER, ISE_CLI_ADMIN_PASSWORD   (CLI admin the broker uses)
#   ISE_TARGET_USER        – GUI admin to reset (e.g. "admin")
# Optional env vars:
#   ISE_NEW_PASSWORD, ISE_PASSWORD_LENGTH (default 20), ISE_KNOWN_HOSTS, ISE_ACCEPT_HOST_KEY
#
# Stdout: one JSON line {"login","hostname","password","url"}
# ============================================================
set -euo pipefail
: "${ISE_HOST:?}"; : "${ISE_CLI_ADMIN_USER:?}"; : "${ISE_CLI_ADMIN_PASSWORD:?}"; : "${ISE_TARGET_USER:?ISE_TARGET_USER is not set.}"
export ISE_TARGET_USER
export ISE_KNOWN_HOSTS="${ISE_KNOWN_HOSTS:-}"
export ISE_ACCEPT_HOST_KEY="${ISE_ACCEPT_HOST_KEY:-false}"
ISE_PASSWORD_LENGTH="${ISE_PASSWORD_LENGTH:-20}"
if [[ -z "${ISE_NEW_PASSWORD:-}" ]]; then
    # ISE GUI admin password policy requires upper, lower, digit; keep alphanumeric
    _rand="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
    ISE_NEW_PASSWORD="A1a${_rand:0:$((ISE_PASSWORD_LENGTH - 3))}"; unset _rand
fi
export ISE_NEW_PASSWORD
export ISE_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ise-ssh-common.exp"
command -v expect >/dev/null || { echo "ERROR: 'expect' is not installed." >&2; exit 1; }
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

echo "Resetting ISE GUI admin '${ISE_TARGET_USER}' on ${ISE_HOST}" >&2

expect -f - <<'EXPECT_SCRIPT'
source $env(ISE_COMMON)
set target_user $env(ISE_TARGET_USER)
set new_pass    $env(ISE_NEW_PASSWORD)
set timeout 60

send "application reset-passwd ise $target_user\r"
expect {
    -nocase -re {enter new password:} { send "$new_pass\r" }
    -re {% .*[\r\n]|Error[^\r\n]*}   { puts stderr "  ERROR: $expect_out(0,string)"; exit 1 }
    timeout { puts stderr "  ERROR: no 'Enter new password' prompt (is '$target_user' a GUI admin?)"; exit 1 }
}
expect {
    -nocase -re {confirm new password:} { send "$new_pass\r" }
    timeout { puts stderr "  ERROR: no confirmation prompt"; exit 1 }
}
expect {
    -nocase -re {password reset successfully|password has been reset|successfully} {}
    -nocase -re {does not (meet|satisfy)|policy|invalid|error|fail} {
        puts stderr "  ERROR: ISE rejected the new password: $expect_out(0,string)"; exit 1
    }
    -re $prompt { puts stderr "  WARNING: no explicit success message; returned to prompt." }
    timeout { puts stderr "  ERROR: timed out waiting for reset result"; exit 1 }
}
expect { -re $prompt {} timeout {} }
puts stderr "  Reset GUI admin '$target_user' on $host."
send "exit\r"
expect eof
EXPECT_SCRIPT

printf '{"login":"%s","hostname":"%s","password":"%s","url":"https://%s/admin/"}\n' \
    "$(json_escape "${ISE_TARGET_USER}")" "$(json_escape "${ISE_HOST}")" "$(json_escape "${ISE_NEW_PASSWORD}")" "${ISE_HOST}"
