#!/usr/bin/env bash
# ============================================================
# Cisco IOS XE Account Password Rotation – Multiple Switches
# ============================================================
# Rotates the password for a local user account across a
# group of Cisco Catalyst 9300 (IOS XE) switches via SSH.
# Each switch is processed in sequence. Results are reported
# per-switch; the script exits 1 if any switch fails.
#
# Required env vars:
#   CISCO_SWITCH_HOSTS    – Comma-separated list of switch IPs
#                           or hostnames (e.g. "10.0.1.1,10.0.1.2")
#   CISCO_ADMIN_USER      – Admin username (same across all switches)
#   CISCO_ADMIN_PASSWORD  – Admin password (same across all switches)
#   CISCO_TARGET_USER     – Local username whose password to rotate
#   CISCO_NEW_PASSWORD    – The new password to set
#
# Optional env vars:
#   CISCO_ENABLE_SECRET   – Enable mode secret (only needed if the
#                           admin account is not privilege 15)
#   CISCO_PRIVILEGE_LEVEL – Privilege level for the target user
#                           (default: 15)
# ============================================================

set -euo pipefail

# ─── Validate required environment variables ─────────────────────────────────

: "${CISCO_SWITCH_HOSTS:?CISCO_SWITCH_HOSTS is not set. Provide a comma-separated list of switch IPs/hostnames.}"
: "${CISCO_ADMIN_USER:?CISCO_ADMIN_USER is not set. Cannot authenticate to switches.}"
: "${CISCO_ADMIN_PASSWORD:?CISCO_ADMIN_PASSWORD is not set. Cannot authenticate to switches.}"
: "${CISCO_TARGET_USER:?CISCO_TARGET_USER is not set. Cannot identify target account.}"
: "${CISCO_NEW_PASSWORD:?CISCO_NEW_PASSWORD is not set. Cannot rotate password.}"

# Apply defaults and export so the expect subprocess can read via $env()
export CISCO_PRIVILEGE_LEVEL="${CISCO_PRIVILEGE_LEVEL:-15}"
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

# ─── Parse and validate the switch host list ─────────────────────────────────

declare -a switch_hosts=()
IFS=',' read -ra raw_hosts <<< "${CISCO_SWITCH_HOSTS}"
for h in "${raw_hosts[@]}"; do
    # Strip all whitespace (hostnames and IPs never contain whitespace)
    h="${h//[[:space:]]/}"
    [[ -n "${h}" ]] && switch_hosts+=("${h}")
done

if (( ${#switch_hosts[@]} == 0 )); then
    echo "ERROR: CISCO_SWITCH_HOSTS is set but contains no valid entries after parsing." >&2
    exit 1
fi

# ─── Helper: open SSH shell, rotate password, save config on one switch ───────

rotate_password() {
    local switch_host="$1"
    echo "  [${switch_host}] Connecting via SSH..."

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
set priv_level    $env(CISCO_PRIVILEGE_LEVEL)

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
        puts stderr "  \[$switch_host\] ERROR: Timed out waiting for SSH password prompt."
        exit 1
    }
    eof {
        puts stderr "  \[$switch_host\] ERROR: SSH connection closed unexpectedly."
        exit 1
    }
}

# ── Wait for the initial EXEC prompt (> or #) ─────────────────────────────────
expect {
    -re {[>#]} { set prompt $expect_out(0,string) }
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Timed out waiting for initial shell prompt."
        exit 1
    }
}

# ── If in user EXEC mode (>), elevate to privileged EXEC (#) ─────────────────
if {[string match "*>*" $prompt]} {
    puts "  \[$switch_host\] Entering privileged EXEC mode via 'enable'..."
    send "enable\r"
    expect {
        -nocase -re {password:} { send "$enable_secret\r" }
        timeout {
            puts stderr "  \[$switch_host\] ERROR: Timed out waiting for enable password prompt."
            exit 1
        }
    }
    expect {
        -re {#} { puts "  \[$switch_host\] Privileged EXEC mode entered." }
        timeout {
            puts stderr "  \[$switch_host\] ERROR: Failed to enter privileged EXEC mode. Verify CISCO_ENABLE_SECRET."
            exit 1
        }
    }
}

# ── Enter global configuration mode ──────────────────────────────────────────
puts "  \[$switch_host\] Entering global configuration mode..."
send "configure terminal\r"
expect {
    -re {\(config\)#} {}
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Failed to enter global configuration mode."
        exit 1
    }
}

# ── Rotate the password (scrypt / type-9 hash – IOS XE 16.x+) ───────────────
puts "  \[$switch_host\] Setting new password for user: $target_user"
send "username $target_user privilege $priv_level algorithm-type scrypt secret $new_password\r"
expect {
    -re {\(config\)#} {}
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Timed out waiting for config prompt after setting password."
        exit 1
    }
}

# ── Exit configuration mode ───────────────────────────────────────────────────
send "end\r"
expect {
    -re {#} {}
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Timed out after 'end' command."
        exit 1
    }
}

# ── Persist to NVRAM ──────────────────────────────────────────────────────────
puts "  \[$switch_host\] Saving configuration to NVRAM..."
send "write memory\r"
set timeout 30
expect {
    -re {\[OK\]|Building configuration|Copy in progress} {}
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Timed out waiting for 'write memory' to complete."
        exit 1
    }
}

# Drain remaining output and wait for the final privileged prompt
set timeout 5
expect { -re {#} {} timeout {} }

puts "  \[$switch_host\] Configuration saved. Rotation succeeded."
exit 0
EXPECT_SCRIPT
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "Starting Cisco IOS XE password rotation across ${#switch_hosts[@]} switch(es)."
echo "  Admin user      : ${CISCO_ADMIN_USER}"
echo "  Target user     : ${CISCO_TARGET_USER}"
echo "  Privilege level : ${CISCO_PRIVILEGE_LEVEL}"
echo "  Switches        : $(IFS=', '; echo "${switch_hosts[*]}")"
echo ""

# ─── Rotate password on each switch sequentially ─────────────────────────────

declare -a results=()

for switch_host in "${switch_hosts[@]}"; do
    echo "─── Processing switch: ${switch_host} ───────────────────────────────────────"
    if rotate_password "${switch_host}"; then
        results+=("OK|${switch_host}")
    else
        results+=("FAIL|${switch_host}")
    fi
    echo ""
done

# ─── Print summary ────────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════════"
echo "Rotation Summary – user '${CISCO_TARGET_USER}'"
echo "═══════════════════════════════════════════════════════════════"

failed_count=0
for result in "${results[@]}"; do
    status="${result%%|*}"
    host="${result#*|}"
    if [[ "${status}" == "OK" ]]; then
        echo "  [OK]    ${host}"
    else
        echo "  [FAIL]  ${host}"
        (( failed_count++ )) || true
    fi
done

echo "═══════════════════════════════════════════════════════════════"

if (( failed_count > 0 )); then
    echo "ERROR: Password rotation completed with ${failed_count} failure(s) out of ${#switch_hosts[@]} switch(es). Review the summary above." >&2
    exit 1
fi

echo "All ${#switch_hosts[@]} switch(es) rotated successfully."
exit 0
