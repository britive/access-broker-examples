#!/usr/bin/env bash
# ============================================================
# Cisco IOS XE – Privilege Escalation Checkout (Single Switch)
# ============================================================
# Creates a local user account with elevated privilege on a
# Cisco Catalyst 9300 (IOS XE) switch via SSH using expect.
# Used by the Britive Access Broker for Just-In-Time (JIT)
# privileged access: the account is created on checkout and
# removed on checkin.
#
# Required env vars:
#   CISCO_SWITCH_HOST         – IP address or hostname of the switch
#   CISCO_ADMIN_USER          – Admin username for the SSH session
#   CISCO_ADMIN_PASSWORD      – Admin password for the SSH session
#   CISCO_TARGET_USER         – Local username to create / escalate
#   CISCO_TARGET_PASSWORD     – Password to set on the target account
#
# Optional env vars:
#   CISCO_ENABLE_SECRET       – Enable mode secret (only needed if
#                               the admin account is not privilege 15)
#   CISCO_ESCALATED_PRIVILEGE – Privilege level to grant (default: 15)
# ============================================================

set -euo pipefail

# ─── Validate required environment variables ─────────────────────────────────

: "${CISCO_SWITCH_HOST:?CISCO_SWITCH_HOST is not set. Cannot identify target switch.}"
: "${CISCO_ADMIN_USER:?CISCO_ADMIN_USER is not set. Cannot authenticate to switch.}"
: "${CISCO_ADMIN_PASSWORD:?CISCO_ADMIN_PASSWORD is not set. Cannot authenticate to switch.}"
: "${CISCO_TARGET_USER:?CISCO_TARGET_USER is not set. Cannot identify target account.}"
: "${CISCO_TARGET_PASSWORD:?CISCO_TARGET_PASSWORD is not set. Cannot set account password.}"

# Apply defaults and export so the expect subprocess can read via $env()
export CISCO_ESCALATED_PRIVILEGE="${CISCO_ESCALATED_PRIVILEGE:-15}"
export CISCO_ENABLE_SECRET="${CISCO_ENABLE_SECRET:-}"

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

# ─── Helper: open SSH shell, create/escalate user, save config ───────────────

checkout_privilege() {
    local switch_host="$1"
    echo "  Connecting to ${switch_host} via SSH..."

    # Pass the per-call host via env; all other CISCO_* vars are already exported.
    SWITCH_HOST="${switch_host}" expect -f - <<'EXPECT_SCRIPT'
set timeout 15
log_user 0

set switch_host        $env(SWITCH_HOST)
set admin_user         $env(CISCO_ADMIN_USER)
set admin_pass         $env(CISCO_ADMIN_PASSWORD)
set target_user        $env(CISCO_TARGET_USER)
set target_password    $env(CISCO_TARGET_PASSWORD)
set enable_secret      $env(CISCO_ENABLE_SECRET)
set escalated_priv     $env(CISCO_ESCALATED_PRIVILEGE)

# ── Spawn SSH – disable strict host-key checking (matches Posh-SSH -AcceptKey) ──
spawn ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -l $admin_user $switch_host

# ── SSH password prompt ───────────────────────────────────────────────────────
expect {
    -nocase -re {password:} { send "$admin_pass\r" }
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
    -re {[>#]} { set prompt $expect_out(0,string) }
    timeout {
        puts stderr "  ERROR: Timed out waiting for initial shell prompt on $switch_host."
        exit 1
    }
}

# ── If in user EXEC mode (>), elevate to privileged EXEC (#) ─────────────────
if {[string match "*>*" $prompt]} {
    puts "  Entering privileged EXEC mode via 'enable'..."
    send "enable\r"
    expect {
        -nocase -re {password:} { send "$enable_secret\r" }
        timeout {
            puts stderr "  ERROR: Timed out waiting for enable password prompt on $switch_host."
            exit 1
        }
    }
    expect {
        -re {#} { puts "  Privileged EXEC mode entered." }
        timeout {
            puts stderr "  ERROR: Failed to enter privileged EXEC mode on $switch_host. Verify CISCO_ENABLE_SECRET."
            exit 1
        }
    }
}

# ── Enter global configuration mode ──────────────────────────────────────────
puts "  Entering global configuration mode..."
send "configure terminal\r"
expect {
    -re {\(config\)#} {}
    timeout {
        puts stderr "  ERROR: Failed to enter global configuration mode on $switch_host."
        exit 1
    }
}

# ── Create / escalate user (scrypt / type-9 hash – IOS XE 16.x+) ─────────────
puts "  Creating / escalating user '$target_user' to privilege $escalated_priv..."
send "username $target_user privilege $escalated_priv algorithm-type scrypt secret $target_password\r"
expect {
    -re {\(config\)#} {}
    timeout {
        puts stderr "  ERROR: Timed out waiting for config prompt after creating user on $switch_host."
        exit 1
    }
}

# ── Exit configuration mode ───────────────────────────────────────────────────
send "end\r"
expect {
    -re {#} {}
    timeout {
        puts stderr "  ERROR: Timed out after 'end' command on $switch_host."
        exit 1
    }
}

# ── Persist to NVRAM ──────────────────────────────────────────────────────────
puts "  Saving configuration to NVRAM..."
send "write memory\r"
set timeout 30
expect {
    -re {\[OK\]|Building configuration|Copy in progress} {}
    timeout {
        puts stderr "  ERROR: Timed out waiting for 'write memory' to complete on $switch_host."
        exit 1
    }
}

# Drain remaining output and wait for the final privileged prompt
set timeout 5
expect { -re {#} {} timeout {} }

puts "  Configuration saved."
puts "  User '$target_user' created/escalated to privilege $escalated_priv on $switch_host."
exit 0
EXPECT_SCRIPT
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "Starting Cisco IOS XE privilege checkout (account creation)."
echo "  Target switch      : ${CISCO_SWITCH_HOST}"
echo "  Admin user         : ${CISCO_ADMIN_USER}"
echo "  Target user        : ${CISCO_TARGET_USER}"
echo "  Escalated privilege: ${CISCO_ESCALATED_PRIVILEGE}"

if ! checkout_privilege "${CISCO_SWITCH_HOST}"; then
    echo "ERROR: Checkout FAILED for user '${CISCO_TARGET_USER}' on switch '${CISCO_SWITCH_HOST}'." >&2
    exit 1
fi

echo "Checkout completed: user '${CISCO_TARGET_USER}' has privilege ${CISCO_ESCALATED_PRIVILEGE} on switch '${CISCO_SWITCH_HOST}'."
exit 0
