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
#
# Optional env vars:
#   CISCO_NEW_PASSWORD    – The new password to set. If unset, a strong
#                           random value is generated and returned on
#                           stdout as JSON so the broker can store it
#   CISCO_PASSWORD_LENGTH – Length of the generated value (default: 20)
#   CISCO_ENABLE_SECRET   – Enable mode secret (only needed if the
#                           admin account is not privilege 15)
#   CISCO_PRIVILEGE_LEVEL – Privilege level for the target user
#                           (default: 15)
#   CISCO_KNOWN_HOSTS         – Path to a known_hosts file holding the
#                               switch host key (default: ~/.ssh/known_hosts,
#                               strict checking ON)
#   CISCO_ACCEPT_HOST_KEY     – "true" to accept unknown host keys on first
#                               connect (lab use only; default: false)
# ============================================================

set -euo pipefail

# ─── Validate required environment variables ─────────────────────────────────

: "${CISCO_SWITCH_HOSTS:?CISCO_SWITCH_HOSTS is not set. Provide a comma-separated list of switch IPs/hostnames.}"
: "${CISCO_ADMIN_USER:?CISCO_ADMIN_USER is not set. Cannot authenticate to switches.}"
: "${CISCO_ADMIN_PASSWORD:?CISCO_ADMIN_PASSWORD is not set. Cannot authenticate to switches.}"
: "${CISCO_TARGET_USER:?CISCO_TARGET_USER is not set. Cannot identify target account.}"

# Apply defaults and export so the expect subprocess can read via $env()
export CISCO_PRIVILEGE_LEVEL="${CISCO_PRIVILEGE_LEVEL:-15}"
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
    echo "  [${switch_host}] Connecting via SSH..." >&2

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
    -re {(^|[\r\n])[^\r\n]*[>#] ?$} { set prompt $expect_out(0,string) }
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Timed out waiting for initial shell prompt."
        exit 1
    }
}

# ── If in user EXEC mode (>), elevate to privileged EXEC (#) ─────────────────
if {[string match "*>*" $prompt]} {
    puts stderr "  \[$switch_host\] Entering privileged EXEC mode via 'enable'..."
    send "enable\r"
    expect {
        -nocase -re {password:} { send "$enable_secret\r" }
        timeout {
            puts stderr "  \[$switch_host\] ERROR: Timed out waiting for enable password prompt."
            exit 1
        }
    }
    expect {
        -re {(^|[\r\n])[^\r\n]*# ?$} { puts stderr "  \[$switch_host\] Privileged EXEC mode entered." }
        timeout {
            puts stderr "  \[$switch_host\] ERROR: Failed to enter privileged EXEC mode. Verify CISCO_ENABLE_SECRET."
            exit 1
        }
    }
}

# ── Enter global configuration mode ──────────────────────────────────────────
puts stderr "  \[$switch_host\] Entering global configuration mode..."
send "configure terminal\r"
expect {
    -re {\(config\)#} {}
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Failed to enter global configuration mode."
        exit 1
    }
}

# ── Rotate the password (scrypt / type-9 hash – IOS XE 16.x+) ───────────────
puts stderr "  \[$switch_host\] Setting new password for user: $target_user"
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
    -re {(^|[\r\n])[^\r\n]*# ?$} {}
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Timed out after 'end' command."
        exit 1
    }
}

# ── Persist to NVRAM ──────────────────────────────────────────────────────────
puts stderr "  \[$switch_host\] Saving configuration to NVRAM..."
send "write memory\r"
set timeout 30
expect {
    -re {\[OK\]|Building configuration|Copy in progress} {}
    timeout {
        puts stderr "  \[$switch_host\] ERROR: Timed out waiting for 'write memory' to complete."
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

puts stderr "  \[$switch_host\] Configuration saved. Rotation succeeded."
exit 0
EXPECT_SCRIPT
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "Starting Cisco IOS XE password rotation across ${#switch_hosts[@]} switch(es)." >&2
echo "  Admin user      : ${CISCO_ADMIN_USER}" >&2
echo "  Target user     : ${CISCO_TARGET_USER}" >&2
echo "  Privilege level : ${CISCO_PRIVILEGE_LEVEL}" >&2
echo "  Switches        : $(IFS=', '; echo "${switch_hosts[*]}")" >&2
echo "" >&2

# ─── Rotate password on each switch sequentially ─────────────────────────────

declare -a results=()

for switch_host in "${switch_hosts[@]}"; do
    echo "─── Processing switch: ${switch_host} ───────────────────────────────────────" >&2
    if rotate_password "${switch_host}"; then
        results+=("OK|${switch_host}")
    else
        results+=("FAIL|${switch_host}")
    fi
    echo "" >&2
done

# ─── Print summary ────────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════════" >&2
echo "Rotation Summary – user '${CISCO_TARGET_USER}'" >&2
echo "═══════════════════════════════════════════════════════════════" >&2

failed_count=0
for result in "${results[@]}"; do
    status="${result%%|*}"
    host="${result#*|}"
    if [[ "${status}" == "OK" ]]; then
        echo "  [OK]    ${host}" >&2
    else
        echo "  [FAIL]  ${host}" >&2
        (( failed_count++ )) || true
    fi
done

echo "═══════════════════════════════════════════════════════════════" >&2

# ─── Emit the result as JSON on stdout (the only stdout output) ──────────────
# Emitted even on partial failure so the broker can store the new secret for
# the switches that did rotate; the exit code still signals the failure.
results_json=""
for result in "${results[@]}"; do
    status="${result%%|*}"
    host="${result#*|}"
    results_json+="${results_json:+,}{\"hostname\":\"$(json_escape "${host}")\",\"status\":\"${status}\"}"
done
printf '{"login":"%s","password":"%s","rotated":%d,"failed":%d,"results":[%s]}\n' \
    "$(json_escape "${CISCO_TARGET_USER}")" \
    "$(json_escape "${CISCO_NEW_PASSWORD}")" \
    "$(( ${#switch_hosts[@]} - failed_count ))" \
    "${failed_count}" \
    "${results_json}"

if (( failed_count > 0 )); then
    echo "ERROR: Password rotation completed with ${failed_count} failure(s) out of ${#switch_hosts[@]} switch(es). Review the summary above." >&2
    exit 1
fi

echo "All ${#switch_hosts[@]} switch(es) rotated successfully." >&2
exit 0
