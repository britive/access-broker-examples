#!/usr/bin/env bash
# ============================================================
# Cisco IOS XE – Privilege Escalation Checkin (Single Switch)
# ============================================================
# Removes a local user account from a Cisco Catalyst 9300
# (IOS XE) switch via SSH using expect.
# Used by the Britive Access Broker for Just-In-Time (JIT)
# privileged access: the account is created on checkout and
# removed on checkin.
#
# Required env vars:
#   CISCO_SWITCH_HOST    – IP address or hostname of the switch
#   CISCO_ADMIN_USER     – Admin username for the SSH session
#   CISCO_ADMIN_PASSWORD – Admin password for the SSH session
#   CISCO_TARGET_USER    – Target identity as an email address
#                          (e.g. alice@example.com). The domain is
#                          stripped to derive the local switch username.
#
# Optional env vars:
#   CISCO_ENABLE_SECRET  – Enable mode secret (only needed if
#                          the admin account is not privilege 15)
#   CISCO_JIT_PREFIX     – Must match the value used at checkout
#                          (default: "brt-")
#   CISCO_CHECKIN_RETRIES – Extra attempts if the removal fails
#                          (default: 1)
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

# CISCO_TARGET_USER is supplied as an email address (e.g. alice@example.com).
# Strip the domain to derive the local switch username (IOS usernames cannot
# contain '@'). If no '@' is present, the value is used unchanged.
CISCO_TARGET_IDENTITY="${CISCO_TARGET_USER}"
CISCO_TARGET_USER="${CISCO_TARGET_USER%%@*}"
: "${CISCO_TARGET_USER:?CISCO_TARGET_USER resolved to an empty username after stripping the domain.}"

# Apply the same prefix the checkout script used (default "brt-").
CISCO_JIT_PREFIX="${CISCO_JIT_PREFIX-brt-}"
CISCO_TARGET_USER="${CISCO_JIT_PREFIX}${CISCO_TARGET_USER}"
export CISCO_TARGET_USER
CISCO_CHECKIN_RETRIES="${CISCO_CHECKIN_RETRIES:-1}"

# Apply defaults and export so the expect subprocess can read via $env()
export CISCO_ENABLE_SECRET="${CISCO_ENABLE_SECRET:-}"
export CISCO_KNOWN_HOSTS="${CISCO_KNOWN_HOSTS:-}"
export CISCO_ACCEPT_HOST_KEY="${CISCO_ACCEPT_HOST_KEY:-false}"

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

# ─── Helper: open SSH shell, remove user, save config ────────────────────────

checkin_privilege() {
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

# ── Remove the user account ───────────────────────────────────────────────────
# IOS XE 17.x prompts for confirmation when removing a username:
#   "This operation will remove all username related configurations ...
#    Do you want to continue? [confirm]"
# Accept the confirmation if it appears, then wait for the config prompt.
puts stderr "  Removing user '$target_user'..."
send "no username $target_user\r"
expect {
    -nocase -re {\[confirm\]|continue\?} {
        send "\r"
        exp_continue
    }
    -re {\(config\)#} {}
    timeout {
        puts stderr "  ERROR: Timed out waiting for config prompt after removing user on $switch_host."
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

# ── Verify the account is gone before saving ─────────────────────────────────
send "terminal length 0\r"
expect {
    -re $priv_prompt {}
    timeout {}
}
send "show running-config | include ^username $target_user \r"
set still_present 0
expect {
    -ex "\nusername $target_user " { set still_present 1; exp_continue }
    -re $priv_prompt {}
    timeout {
        puts stderr "  ERROR: Timed out verifying removal of '$target_user' on $switch_host."
        exit 1
    }
}
if {$still_present} {
    puts stderr "  ERROR: '$target_user' is still present in the running configuration after 'no username'."
    exit 1
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
puts stderr "  User '$target_user' removed from $switch_host."
exit 0
EXPECT_SCRIPT
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "Starting Cisco IOS XE privilege checkin (account removal)." >&2
echo "  Target switch : ${CISCO_SWITCH_HOST}" >&2
echo "  Admin user    : ${CISCO_ADMIN_USER}" >&2
echo "  Target identity : ${CISCO_TARGET_IDENTITY}" >&2
echo "  Target user     : ${CISCO_TARGET_USER}" >&2

# A failed checkin leaves a standing privileged account behind, so retry
# before giving up. The sequence is idempotent: 'no username' on an account
# that is already gone is a no-op and verification still passes.
attempt=0
until checkin_privilege "${CISCO_SWITCH_HOST}"; do
    attempt=$((attempt + 1))
    if (( attempt > CISCO_CHECKIN_RETRIES )); then
        echo "ERROR: Checkin FAILED for user '${CISCO_TARGET_USER}' on switch '${CISCO_SWITCH_HOST}' after $((attempt)) attempt(s). Remove manually: 'no username ${CISCO_TARGET_USER}'." >&2
        exit 1
    fi
    echo "  Checkin attempt ${attempt} failed; retrying in 5s..." >&2
    sleep 5
done

echo "Checkin completed: user '${CISCO_TARGET_USER}' removed from switch '${CISCO_SWITCH_HOST}'." >&2
exit 0
