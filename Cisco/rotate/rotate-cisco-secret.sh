#!/usr/bin/env bash
# ============================================================
# Cisco IOS XE Account Secret Rotation – Single Switch
# ============================================================
# Rotates the stored secret (password hash) for a local user
# account on a single Cisco Catalyst 9300 (IOS XE) switch
# via SSH using expect, without modifying the account's
# privilege level.
# Used by the Britive broker to reset network device
# credentials as part of a checkout/checkin workflow.
#
# Required env vars:
#   CISCO_SWITCH_HOST     – IP address or hostname of the switch
#   CISCO_ADMIN_USER      – Admin username for the SSH session
#   CISCO_ADMIN_PASSWORD  – Admin password for the SSH session
#   CISCO_TARGET_USER     – Local username whose secret to rotate
#
# Optional env vars:
#   CISCO_NEW_PASSWORD    – The new secret to set. If unset, a strong
#                           random value is generated and returned on
#                           stdout as JSON so the broker can store it
#   CISCO_PASSWORD_LENGTH – Length of the generated value (default: 20)
#   CISCO_ENABLE_SECRET   – Enable mode secret (only needed if the
#                           admin account is not privilege 15)
#   CISCO_KNOWN_HOSTS         – Path to a known_hosts file holding the
#                               switch host key (default: ~/.ssh/known_hosts,
#                               strict checking ON)
#   CISCO_ACCEPT_HOST_KEY     – "true" to accept unknown host keys on first
#                               connect (lab use only; default: false)
# ============================================================

set -euo pipefail

# ─── Validate required environment variables ─────────────────────────────────

: "${CISCO_SWITCH_HOST:?CISCO_SWITCH_HOST is not set. Cannot identify target switch.}"
: "${CISCO_ADMIN_USER:?CISCO_ADMIN_USER is not set. Cannot authenticate to switch.}"
: "${CISCO_ADMIN_PASSWORD:?CISCO_ADMIN_PASSWORD is not set. Cannot authenticate to switch.}"
: "${CISCO_TARGET_USER:?CISCO_TARGET_USER is not set. Cannot identify target account.}"

# Export so the expect subprocess can read via $env()
export CISCO_ENABLE_SECRET="${CISCO_ENABLE_SECRET:-}"
export CISCO_KNOWN_HOSTS="${CISCO_KNOWN_HOSTS:-}"
export CISCO_ACCEPT_HOST_KEY="${CISCO_ACCEPT_HOST_KEY:-false}"

# ─── Generate the new secret if the caller did not supply one ────────────────
# Alphanumerics only: avoids IOS CLI / expect special-character issues
# ('?', '$', spaces) while still giving a strong secret. The new value is
# returned on stdout (JSON) so the broker can write it back to the Britive
# Secrets Store; it is never printed anywhere else.
export CISCO_PASSWORD_LENGTH="${CISCO_PASSWORD_LENGTH:-20}"
if [[ -z "${CISCO_NEW_PASSWORD:-}" ]]; then
    _rand_alnum="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
    CISCO_NEW_PASSWORD="${_rand_alnum:0:${CISCO_PASSWORD_LENGTH}}"
    unset _rand_alnum
    if [[ "${#CISCO_NEW_PASSWORD}" -lt "${CISCO_PASSWORD_LENGTH}" ]]; then
        echo "ERROR: Failed to generate a random password." >&2
        exit 1
    fi
fi
export CISCO_NEW_PASSWORD

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
set new_password  $env(CISCO_NEW_PASSWORD)
set enable_secret $env(CISCO_ENABLE_SECRET)

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

spawn ssh \
    {*}$hostkey_opts \
    -o ConnectTimeout=10 \
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
        -re {(^|[\r\n])[^\r\n]*# ?$} { puts stderr "  Privileged EXEC mode entered." }
        timeout {
            puts stderr "  ERROR: Failed to enter privileged EXEC mode on $switch_host. Verify CISCO_ENABLE_SECRET."
            exit 1
        }
    }
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
    -re {\(config\)#} {}
    timeout {
        puts stderr "  ERROR: Timed out waiting for config prompt after setting secret on $switch_host."
        exit 1
    }
}

# ── Exit configuration mode ───────────────────────────────────────────────────
send "end\r"
expect {
    -re {(^|[\r\n])[^\r\n]*# ?$} {}
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
    -re {(^|[\r\n])[^\r\n]*# ?$} {}
    timeout {}
}

puts stderr "  Configuration saved."
puts stderr "  Secret rotation completed successfully on $switch_host."
exit 0
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

echo "Secret rotation completed successfully for user '${CISCO_TARGET_USER}' on switch '${CISCO_SWITCH_HOST}'." >&2

# ─── Emit the result as JSON on stdout (the only stdout output) ──────────────
# The broker captures this to update the stored secret for the account.
printf '{"login":"%s","hostname":"%s","password":"%s"}\n' \
    "$(json_escape "${CISCO_TARGET_USER}")" \
    "$(json_escape "${CISCO_SWITCH_HOST}")" \
    "$(json_escape "${CISCO_NEW_PASSWORD}")"
exit 0
