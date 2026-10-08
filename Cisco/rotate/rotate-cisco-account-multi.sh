#!/usr/bin/env bash
# ============================================================
# Cisco IOS XE Account Password Rotation – Multiple Switches
# ============================================================
# Rotates the password for an existing local user account
# across a group of Cisco Catalyst 9300 (IOS XE) switches via
# SSH, setting its privilege level and logging in as the account
# with the new password on each switch to prove it took.
# Each switch is processed in sequence. Results are reported
# per-switch; the script exits 1 if any switch fails.
#
# Device connection values are read from CISCO_* first and fall
# back to the resource attributes the broker injects for a
# rotation (RESOURCE_<NAME>, upper-cased):
#   CISCO_SWITCH_HOSTS   / RESOURCE_SWITCH_HOSTS   – comma-separated switch
#                          IPs or hostnames (e.g. "10.0.1.1,10.0.1.2")
#   CISCO_ADMIN_USER     / RESOURCE_ADMIN_USER     – admin username (same on
#                          all switches)
#   CISCO_ADMIN_PASSWORD / RESOURCE_ADMIN_PASSWORD – admin password (same on
#                          all switches)
#   CISCO_ENABLE_SECRET  / RESOURCE_ENABLE_SECRET  – enable secret (optional;
#                          only needed if the admin is not privilege 15)
#
# Required env vars (rotation / permission attributes):
#   CISCO_TARGET_USER     – Existing local username whose password to rotate
#   CISCO_NEW_PASSWORD    – The new password. Supplied by the caller (Britive's
#                           rotation module generates it); never generated
#                           here, because a value Britive did not produce
#                           could not be stored or vended afterwards.
#
# Optional env vars:
#   CISCO_PRIVILEGE_LEVEL     – Privilege level for the target user
#                               (default: 15)
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

export CISCO_SWITCH_HOSTS="${CISCO_SWITCH_HOSTS:-${RESOURCE_SWITCH_HOSTS:-}}"
export CISCO_ADMIN_USER="${CISCO_ADMIN_USER:-${RESOURCE_ADMIN_USER:-}}"
export CISCO_ADMIN_PASSWORD="${CISCO_ADMIN_PASSWORD:-${RESOURCE_ADMIN_PASSWORD:-}}"
export CISCO_ENABLE_SECRET="${CISCO_ENABLE_SECRET:-${RESOURCE_ENABLE_SECRET:-}}"

# ─── Validate required environment variables ─────────────────────────────────

: "${CISCO_SWITCH_HOSTS:?CISCO_SWITCH_HOSTS (or resource attribute SWITCH_HOSTS) is not set. Provide a comma-separated list of switch IPs/hostnames.}"
: "${CISCO_ADMIN_USER:?CISCO_ADMIN_USER (or resource attribute ADMIN_USER) is not set. Cannot authenticate to switches.}"
: "${CISCO_ADMIN_PASSWORD:?CISCO_ADMIN_PASSWORD (or resource attribute ADMIN_PASSWORD) is not set. Cannot authenticate to switches.}"
: "${CISCO_TARGET_USER:?CISCO_TARGET_USER is not set. Cannot identify target account.}"
: "${CISCO_NEW_PASSWORD:?CISCO_NEW_PASSWORD is not set. Supply the new password (the Britive rotation module generates it); this script never generates one.}"

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
export CISCO_PRIVILEGE_LEVEL="${CISCO_PRIVILEGE_LEVEL:-15}"
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
set enable_secret $env(CISCO_ENABLE_SECRET)
set priv_level    $env(CISCO_PRIVILEGE_LEVEL)
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

# ── Rotate the password (scrypt / type-9 hash – IOS XE 16.x+) ───────────────
puts stderr "  Setting new password for user: $target_user"
send "username $target_user privilege $priv_level algorithm-type scrypt secret $new_password\r"
expect {
    -re {% Invalid|% Incomplete|% Ambiguous|% Password} {
        puts stderr "  ERROR: $switch_host rejected the new password for '$target_user'."
        exit 1
    }
    -re {\(config\)#} {}
    timeout {
        puts stderr "  ERROR: Timed out waiting for config prompt after setting password on $switch_host."
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
puts stderr "  Password rotation completed successfully on $switch_host."
exit 0
EXPECT_SCRIPT
}

# ─── Helper: log in as the target account with the new secret ────────────────

verify_login() {
    local switch_host="$1"
    echo "  [${switch_host}] Verifying login as '${CISCO_TARGET_USER}' with the new password..." >&2

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
    if ! rotate_password "${switch_host}"; then
        results+=("FAIL|${switch_host}")
    elif [[ "${CISCO_VERIFY_LOGIN}" == "true" ]] && ! verify_login "${switch_host}"; then
        echo "  [${switch_host}] ERROR: Password was applied, but login as '${CISCO_TARGET_USER}' with it FAILED." >&2
        results+=("FAIL|${switch_host}")
    else
        results+=("OK|${switch_host}")
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
login_verified=false
[[ "${CISCO_VERIFY_LOGIN}" == "true" ]] && login_verified=true
printf '{"login":"%s","password":"%s","rotated":%d,"failed":%d,"login_verified":%s,"results":[%s]}\n' \
    "$(json_escape "${CISCO_TARGET_USER}")" \
    "$(json_escape "${CISCO_NEW_PASSWORD}")" \
    "$(( ${#switch_hosts[@]} - failed_count ))" \
    "${failed_count}" \
    "${login_verified}" \
    "${results_json}"

if (( failed_count > 0 )); then
    echo "ERROR: Password rotation completed with ${failed_count} failure(s) out of ${#switch_hosts[@]} switch(es). Review the summary above." >&2
    exit 1
fi

echo "All ${#switch_hosts[@]} switch(es) rotated successfully." >&2
exit 0
