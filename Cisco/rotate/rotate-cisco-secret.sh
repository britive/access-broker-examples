#!/usr/bin/env bash
# ============================================================
# Cisco IOS XE Account Secret Rotation – Single Switch
# ============================================================
# Rotates the stored secret (password hash) for an existing
# local user account on a single Cisco Catalyst 9300 (IOS XE)
# switch via SSH using expect, without modifying the account's
# privilege level, then logs in as that account with the new
# secret to prove it took.
# Used by the Britive broker as a rotation (or as the checkout
# and checkin script of a break-glass permission).
#
# Device connection values are read from CISCO_* first and fall
# back to the resource attributes the broker injects for a
# rotation (RESOURCE_<NAME>, upper-cased):
#   CISCO_SWITCH_HOST    / RESOURCE_SWITCH_HOST    – switch IP or hostname
#   CISCO_ADMIN_USER     / RESOURCE_ADMIN_USER     – admin username for SSH
#   CISCO_ADMIN_PASSWORD / RESOURCE_ADMIN_PASSWORD – admin password for SSH
#   CISCO_ENABLE_SECRET  / RESOURCE_ENABLE_SECRET  – enable secret (optional;
#                          only needed if the admin is not privilege 15)
#
# Required env vars (rotation / permission attributes):
#   CISCO_TARGET_USER     – Existing local username whose secret to rotate
#   CISCO_NEW_PASSWORD    – The new secret. Supplied by the caller (Britive's
#                           rotation module generates it); never generated
#                           here, because a value Britive did not produce
#                           could not be stored or vended afterwards.
#
# Optional env vars:
#   CISCO_VERIFY_LOGIN        – "false" to skip the post-rotation login check
#                               (default: true)
#   CISCO_KNOWN_HOSTS         – Path to a known_hosts file holding the
#                               switch host key (default: ~/.ssh/known_hosts,
#                               strict checking ON)
#   CISCO_ACCEPT_HOST_KEY     – "true" to accept unknown host keys on first
#                               connect (lab use only; default: false)
#
# Secret rules: whitespace is rejected (IOS reads the secret to end of
# line); '?' is sent behind Ctrl-V so the CLI takes it literally.
# ============================================================

set -euo pipefail

# ─── Resolve inputs: CISCO_* wins, RESOURCE_* (rotation) is the fallback ─────

export CISCO_SWITCH_HOST="${CISCO_SWITCH_HOST:-${RESOURCE_SWITCH_HOST:-}}"
export CISCO_ADMIN_USER="${CISCO_ADMIN_USER:-${RESOURCE_ADMIN_USER:-}}"
export CISCO_ADMIN_PASSWORD="${CISCO_ADMIN_PASSWORD:-${RESOURCE_ADMIN_PASSWORD:-}}"
export CISCO_ENABLE_SECRET="${CISCO_ENABLE_SECRET:-${RESOURCE_ENABLE_SECRET:-}}"

# ─── Validate required environment variables ─────────────────────────────────

: "${CISCO_SWITCH_HOST:?CISCO_SWITCH_HOST (or resource attribute SWITCH_HOST) is not set. Cannot identify target switch.}"
: "${CISCO_ADMIN_USER:?CISCO_ADMIN_USER (or resource attribute ADMIN_USER) is not set. Cannot authenticate to switch.}"
: "${CISCO_ADMIN_PASSWORD:?CISCO_ADMIN_PASSWORD (or resource attribute ADMIN_PASSWORD) is not set. Cannot authenticate to switch.}"
: "${CISCO_TARGET_USER:?CISCO_TARGET_USER is not set. Cannot identify target account.}"
: "${CISCO_NEW_PASSWORD:?CISCO_NEW_PASSWORD is not set. Supply the new secret (the Britive rotation module generates it); this script never generates one.}"

if [[ "${CISCO_NEW_PASSWORD}" =~ [[:space:]] ]]; then
    echo "ERROR: CISCO_NEW_PASSWORD contains whitespace; IOS would truncate the secret. Exclude whitespace from the password policy." >&2
    exit 1
fi
if [[ "${CISCO_TARGET_USER}" == "${CISCO_ADMIN_USER}" ]]; then
    echo "ERROR: Refusing to rotate the broker's own admin account '${CISCO_ADMIN_USER}'." >&2
    exit 1
fi

# Export so the expect subprocess can read via $env()
export CISCO_TARGET_USER CISCO_NEW_PASSWORD
export CISCO_KNOWN_HOSTS="${CISCO_KNOWN_HOSTS:-}"
export CISCO_ACCEPT_HOST_KEY="${CISCO_ACCEPT_HOST_KEY:-false}"
CISCO_VERIFY_LOGIN="${CISCO_VERIFY_LOGIN:-true}"

# Minimal JSON string escaping for caller-supplied values.
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ─── Check dependencies ───────────────────────────────────────────────────────

if ! command -v expect &>/dev/null; then
    echo "ERROR: 'expect' is not installed." \
         "Install with: apt install expect  /  yum install expect  /  brew install expect" >&2
    exit 1
fi

if ! command -v ssh &>/dev/null; then
    echo "ERROR: 'ssh' (OpenSSH client) is not installed." >&2
    exit 1
fi

# ─── Helper: open SSH shell, rotate secret, save config ──────────────────────

rotate_secret() {
    local switch_host="$1"
    echo "  Connecting to ${switch_host} via SSH..." >&2

    # Pass the per-call host via env; all other CISCO_* vars are already exported.
    SWITCH_HOST="${switch_host}" expect -f - <<'EXPECT_SCRIPT'
set timeout 15
log_user 0

set switch_host   $env(SWITCH_HOST)
set admin_user    $env(CISCO_ADMIN_USER)
set admin_pass    $env(CISCO_ADMIN_PASSWORD)
set target_user   $env(CISCO_TARGET_USER)
set enable_secret $env(CISCO_ENABLE_SECRET)
set priv_prompt   {(^|[\r\n])[^\r\n]*# ?$}
# Ctrl-V (0x16) before '?' makes the IOS CLI take it literally instead of
# printing context help.
set new_password  [string map [list "?" "\x16?"] $env(CISCO_NEW_PASSWORD)]

# ── Host-key policy ──────────────────────────────────────────────────────────
# Default: verify the switch host key (StrictHostKeyChecking=yes). Supply a
# pre-populated file via CISCO_KNOWN_HOSTS, or set CISCO_ACCEPT_HOST_KEY=true
# to fall back to trust-on-first-use (lab use only).
set known_hosts $env(CISCO_KNOWN_HOSTS)
set accept_key  $env(CISCO_ACCEPT_HOST_KEY)
if {[string tolower $accept_key] eq "true"} {
    set hostkey_opts [list -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null]
} elseif {$known_hosts ne ""} {
    set hostkey_opts [list -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts]
} else {
    set hostkey_opts [list -o StrictHostKeyChecking=yes]
}

# Password authentication only: a broker host usually carries its own SSH
# keys, which the switch would reject before ever offering a password prompt.
spawn ssh \
    {*}$hostkey_opts \
    -o ConnectTimeout=10 \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive,password \
    -l $admin_user $switch_host

# ── SSH password prompt ───────────────────────────────────────────────────────
expect {
    -nocase -re {password:} { send "$admin_pass\r" }
    -re {Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|No .* host key is known} {
        puts stderr "  ERROR: Host key for $switch_host is unknown or changed. Add it to CISCO_KNOWN_HOSTS (or set CISCO_ACCEPT_HOST_KEY=true for lab use)."
        exit 1
    }
    timeout {
        puts stderr "  ERROR: Timed out waiting for SSH password prompt on $switch_host."
        exit 1
    }
    eof {
        puts stderr "  ERROR: SSH connection to $switch_host closed unexpectedly."
        exit 1
    }
}

# ── Wait for the initial EXEC prompt (> or #) ─────────────────────────────────
expect {
    -re {(^|[\r\n])[^\r\n]*[>#] ?$} { set prompt $expect_out(0,string) }
    -nocase -re {password:} {
        puts stderr "  ERROR: Admin login rejected on $switch_host. Verify CISCO_ADMIN_USER / CISCO_ADMIN_PASSWORD."
        exit 1
    }
    timeout {
        puts stderr "  ERROR: Timed out waiting for initial shell prompt on $switch_host."
        exit 1
    }
}

# ── If in user EXEC mode (>), elevate to privileged EXEC (#) ─────────────────
if {[string match "*>*" $prompt]} {
    puts stderr "  Entering privileged EXEC mode via 'enable'..."
    send "enable\r"
    expect {
        -nocase -re {password:} { send "$enable_secret\r" }
        timeout {
            puts stderr "  ERROR: Timed out waiting for enable password prompt on $switch_host."
            exit 1
        }
    }
    expect {
        -re $priv_prompt { puts stderr "  Privileged EXEC mode entered." }
        timeout {
            puts stderr "  ERROR: Failed to enter privileged EXEC mode on $switch_host. Verify CISCO_ENABLE_SECRET."
            exit 1
        }
    }
}

# ── Pre-flight: rotation only ever changes an existing account ───────────────
send "terminal length 0\r"
expect {
    -re $priv_prompt {}
    timeout {}
}
send "show running-config | include ^username $target_user \r"
set account_exists 0
expect {
    -ex "\nusername $target_user " { set account_exists 1; exp_continue }
    -re $priv_prompt {}
    timeout {
        puts stderr "  ERROR: Timed out checking whether '$target_user' exists on $switch_host."
        exit 1
    }
}
if {!$account_exists} {
    puts stderr "  ERROR: Local account '$target_user' does not exist on $switch_host. Rotation never creates accounts."
    exit 1
}

# ── Enter global configuration mode ──────────────────────────────────────────
puts stderr "  Entering global configuration mode..."
send "configure terminal\r"
expect {
    -re {\(config\)#} {}
    timeout {
        puts stderr "  ERROR: Failed to enter global configuration mode on $switch_host."
        exit 1
    }
}

# ── Rotate the secret (scrypt / type-9 hash – IOS XE 16.x+) ─────────────────
# Omitting the 'privilege' keyword updates only the stored secret hash;
# the account's existing privilege level is preserved unchanged.
puts stderr "  Setting new secret for user: $target_user"
send "username $target_user algorithm-type scrypt secret $new_password\r"
expect {
    -re {% Invalid|% Incomplete|% Ambiguous|% Password} {
        puts stderr "  ERROR: $switch_host rejected the new secret for '$target_user'."
        exit 1
    }
    -re {\(config\)#} {}
    timeout {
        puts stderr "  ERROR: Timed out waiting for config prompt after setting secret on $switch_host."
        exit 1
    }
}

# ── Exit configuration mode ───────────────────────────────────────────────────
send "end\r"
expect {
    -re $priv_prompt {}
    timeout {
        puts stderr "  ERROR: Timed out after 'end' command on $switch_host."
        exit 1
    }
}

# ── Persist to NVRAM ──────────────────────────────────────────────────────────
puts stderr "  Saving configuration to NVRAM..."
send "write memory\r"
set timeout 30
expect {
    -re {\[OK\]|Building configuration|Copy in progress} {}
    timeout {
        puts stderr "  ERROR: Timed out waiting for 'write memory' to complete on $switch_host."
        exit 1
    }
}

# Drain remaining output and wait for the final privileged prompt.
# (A one-line braced expect body is parsed as a single pattern and never
# matches, so the multi-line form is required here.)
set timeout 5
expect {
    -re $priv_prompt {}
    timeout {}
}

puts stderr "  Configuration saved."
puts stderr "  Secret rotation completed successfully on $switch_host."
exit 0
EXPECT_SCRIPT
}

# ─── Helper: log in as the target account with the new secret ────────────────

verify_login() {
    local switch_host="$1"
    echo "  Verifying login as '${CISCO_TARGET_USER}' with the new secret..." >&2

    SWITCH_HOST="${switch_host}" expect -f - <<'EXPECT_SCRIPT'
set timeout 15
log_user 0

set switch_host $env(SWITCH_HOST)
set known_hosts $env(CISCO_KNOWN_HOSTS)
set accept_key  $env(CISCO_ACCEPT_HOST_KEY)
if {[string tolower $accept_key] eq "true"} {
    set hostkey_opts [list -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null]
} elseif {$known_hosts ne ""} {
    set hostkey_opts [list -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts]
} else {
    set hostkey_opts [list -o StrictHostKeyChecking=yes]
}

spawn ssh \
    {*}$hostkey_opts \
    -o ConnectTimeout=10 \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive,password \
    -l $env(CISCO_TARGET_USER) $switch_host

expect {
    -nocase -re {password:} { send "$env(CISCO_NEW_PASSWORD)\r" }
    timeout { exit 1 }
    eof     { exit 1 }
}
expect {
    -re {(^|[\r\n])[^\r\n]*[>#] ?$} { send "exit\r"; exit 0 }
    -nocase -re {password:} { exit 1 }
    timeout { exit 1 }
    eof     { exit 1 }
}
EXPECT_SCRIPT
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "Starting Cisco IOS XE secret rotation." >&2
echo "  Target switch : ${CISCO_SWITCH_HOST}" >&2
echo "  Admin user    : ${CISCO_ADMIN_USER}" >&2
echo "  Target user   : ${CISCO_TARGET_USER}" >&2

if ! rotate_secret "${CISCO_SWITCH_HOST}"; then
    echo "ERROR: Secret rotation FAILED for user '${CISCO_TARGET_USER}' on switch '${CISCO_SWITCH_HOST}'." >&2
    exit 1
fi

login_verified=false
if [[ "${CISCO_VERIFY_LOGIN}" == "true" ]]; then
    if ! verify_login "${CISCO_SWITCH_HOST}"; then
        echo "ERROR: Secret was applied, but login as '${CISCO_TARGET_USER}' with it FAILED on switch '${CISCO_SWITCH_HOST}'. Treat the account as unusable until re-rotated." >&2
        exit 1
    fi
    login_verified=true
    echo "  Login verified." >&2
fi

echo "Secret rotation completed successfully for user '${CISCO_TARGET_USER}' on switch '${CISCO_SWITCH_HOST}'." >&2

# ─── Emit the result as JSON on stdout (the only stdout output) ──────────────
# The broker captures this to update the stored secret for the account.
printf '{"login":"%s","hostname":"%s","password":"%s","login_verified":%s}\n' \
    "$(json_escape "${CISCO_TARGET_USER}")" \
    "$(json_escape "${CISCO_SWITCH_HOST}")" \
    "$(json_escape "${CISCO_NEW_PASSWORD}")" \
    "${login_verified}"
exit 0
