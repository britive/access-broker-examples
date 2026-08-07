#!/bin/bash
# ==============================================================================
# Britive AD rotation: reset a service account password AND update the Windows
# service that runs under it
# ==============================================================================
# Port of the PowerShell "AD Service Account Password Rotation" script to run on
# the Linux Britive Bridge broker (Alpine container) instead of a domain-joined
# Windows host with RSAT.
#
# Rotates the password in AD, unlocks the account, clears the
# must-change-at-next-logon flag, then reaches the target Windows server over
# WinRM to write the new credential onto a service and (by default) restart it.
#
# ------------------------------------------------------------------------------
# HOW WE REACH THE WINDOWS SERVER
# ------------------------------------------------------------------------------
# The original ran `Invoke-Command -ComputerName $TargetServer` with NO
# credential, because it executed as a domain service account on a domain-joined
# host: PSRemoting negotiated Kerberos with the caller's own ticket.
#
# This broker is a Fargate container -- not domain-joined, no ticket cache, no
# SSPI -- so the credential is passed explicitly over NTLM. It is the SAME domain
# account the rest of these scripts bind to AD with (AD_SECRET), which holds
# domain-level rights over the member servers. There is no separate WinRM
# credential to configure.
#
# The password is never re-read from the environment: ad_init writes it to a 0600
# file and unsets the variable, and the WinRM step reads that file.
#
# Required env vars:
#   AD_TARGET_USER    - sAMAccountName of the service account, e.g. svc-app01
#   AD_TARGET_SERVER  - host running the service (FQDN reachable from the broker)
#   AD_SERVICE_NAME   - Windows service name (the short name, not DisplayName)
#   AD_NEW_PASSWORD   - the new password. Britive's secret rotation module
#                       generates it and injects it when the attribute is
#                       configured on the rotation in the UI. This script never
#                       generates one -- see NOTES ON THE PORT.
#
# Connection env vars for AD itself: see lib/ad_common.sh.
#
# Optional env vars:
#   AD_RESTART_SERVICE  - "true" (default) or "false". False writes the
#                         credential and leaves the service on the OLD password
#                         until someone restarts it.
#   AD_NETBIOS_DOMAIN   - NetBIOS domain name used to build the DOMAIN\user logon
#                         account (default: britive). Required for any other
#                         domain: it is not derivable from the base DN.
#   AD_EMIT_PASSWORD    - "true" to print the password on STDOUT for a response
#                         template. Default false: a rotation nobody is told
#                         about is the safe default, and the original never
#                         emitted it.
#   AD_BIND_WINRM_USER  - overrides the WinRM logon name derived from the AD bind
#                         identity. Needed only when the bind DN cannot be mapped
#                         to a DOMAIN\user form automatically.
#   WINRM_PORT          - default 5985 (HTTP) or 5986 (HTTPS)
#   WINRM_NO_SSL        - 1 for HTTP/5985 (default), 0 for HTTPS/5986
#   WINRM_TRANSPORT     - pywinrm transport, default ntlm
#   SERVICE_STOP_TIMEOUT / SERVICE_START_TIMEOUT - seconds, default 60 each
#
# Output (STDOUT): username / password_rotated / account_unlocked /
#                  service_updated / service_restarted
#                  (plus password when AD_EMIT_PASSWORD=true)
#
# ------------------------------------------------------------------------------
# NOTES ON THE PORT
# ------------------------------------------------------------------------------
#   * WinRM PREFLIGHT BEFORE THE ROTATION. The original rotated the AD password
#     first and only then discovered whether the server was reachable and the
#     service existed. Every failure after the reset left a service authenticating
#     with a password nobody holds -- an outage, and unrecoverable, since the old
#     password cannot be read back to undo it. This script proves WinRM auth and
#     the service's existence FIRST, so the common failures cost nothing.
#   * Win32_Service.Change() instead of `sc.exe config obj= password=`. sc.exe
#     takes the password as a command-line argument, so it appears in the remote
#     process table and in any command-line auditing (Sysmon event 1, 4688 with
#     full command line) on the target. The CIM method passes it as a parameter
#     instead.
#   * `Unlock-ADAccount` has no LDAP equivalent; it is a lockoutTime=0 write.
#     `Set-ADUser -ChangePasswordAtLogon $false` is a pwdLastSet=-1 write.
#   * The NetBIOS domain name is a plain default (britive) rather than a
#     Get-ADDomain lookup. It is not derivable from the base DN -- set
#     AD_NETBIOS_DOMAIN on any other domain.
#   * The new password comes from the rotation module, never from this script.
#     A password generated locally would exist only inside this process, so
#     Britive could neither store nor vend it and the credential would be lost
#     at exit. The platform generating it is also what makes the value
#     retrievable afterwards.
# ==============================================================================

set -euo pipefail

# Locate the shared AD helper library. v2/ecr/Dockerfile bakes it into the
# Bridge image; AD_COMMON_LIB overrides the path for local testing.
AD_COMMON_LIB="${AD_COMMON_LIB:-/opt/britive-broker/lib/ad_common.sh}"
if [ ! -r "$AD_COMMON_LIB" ]; then
  printf 'ERROR: AD helper library not readable at %s\n' "$AD_COMMON_LIB" >&2
  printf 'ERROR: rebuild the Bridge image (v2/ecr/Dockerfile installs lib/ad_common.sh) or set AD_COMMON_LIB.\n' >&2
  exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/ad_common.sh
. "$AD_COMMON_LIB"

AD_LOG_TAG="ad-rotate-service-account"

# ------------------------------------------------------------------------------
# Make the failure reason survive truncation.
# ------------------------------------------------------------------------------
# Britive keeps roughly the first 250 characters of the captured output and
# CloudWatch holds nothing more, so a run that logs progress first has its actual
# error cut off -- which is exactly what happened on the first attempts here.
#
# So INFO lines are buffered instead of printed, and die() prints the reason FIRST
# and the buffered trace after it. The error is then always inside the window.
# Bash resolves function names at call time, so these overrides also apply to the
# library's own info/die calls.
#
# AD_VERBOSE=true restores immediate logging, for a hand-run where nothing is
# truncating anything.
AD_TRACE=""
if [ "${AD_VERBOSE:-false}" != "true" ]; then
  info() { AD_TRACE="${AD_TRACE}${1}; "; }
fi

die() {
  AD_DIED=1
  printf '%s [%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$AD_LOG_TAG" "$*" >&2
  [ -n "$AD_TRACE" ] && printf 'trace: %s\n' "$AD_TRACE" >&2
  exit 1
}

# A `set -e` abort never reaches die(), and would otherwise report nothing at all.
ad_trace_exit_trap() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -z "${AD_DIED:-}" ]; then
    printf 'exited %s without a reason; trace: %s\n' "$rc" "${AD_TRACE:-<empty>}" >&2
  fi
}
trap 'ad_trace_exit_trap; ad_cleanup' EXIT INT TERM

# The broker injects the resource's attributes with a RESOURCE_ prefix; the shared
# library reads the AD_* names. Assign them across, plainly. Kept in the script
# rather than the library because Britive re-fetches this script on every run,
# while the library only changes when the image is rebuilt.
#
# AD_TARGET_USER and AD_NEW_PASSWORD are NOT here: the broker passes those under
# their own names already (AD_NEW_PASSWORD arrives encrypted, which is why it does
# not appear in the request log).
#
# An AD_* value set directly wins, so the script stays runnable by hand. Unset
# attributes are left empty on purpose -- ad_init owns the defaults.
AD_HOST="${AD_HOST:-${RESOURCE_HOST:-}}"
AD_BASE_DN="${AD_BASE_DN:-${RESOURCE_BASE_DN:-}}"
AD_SECRET="${AD_SECRET:-${RESOURCE_SECRET:-}}"
AWS_REGION="${AWS_REGION:-${RESOURCE_REGION:-}}"
AD_CA_CERT="${AD_CA_CERT:-${RESOURCE_CA_CERT:-}}"
AD_USER_OU="${AD_USER_OU:-${RESOURCE_USER_OU:-}}"
export AD_HOST AD_BASE_DN AD_SECRET AWS_REGION AD_CA_CERT AD_USER_OU

ad_require_vars AD_TARGET_USER AD_TARGET_SERVER AD_SERVICE_NAME AD_NEW_PASSWORD

EMIT_PASSWORD="${AD_EMIT_PASSWORD:-false}"
RESTART_SERVICE=true
[ "${AD_RESTART_SERVICE:-true}" = "false" ] && RESTART_SERVICE=false
STOP_TIMEOUT="${SERVICE_STOP_TIMEOUT:-60}"
START_TIMEOUT="${SERVICE_START_TIMEOUT:-60}"
WINRM_TRANSPORT="${WINRM_TRANSPORT:-ntlm}"
WINRM_NO_SSL="${WINRM_NO_SSL:-1}"
if [ "$WINRM_NO_SSL" = "1" ]; then
  WINRM_SCHEME=http
  WINRM_PORT="${WINRM_PORT:-5985}"
else
  WINRM_SCHEME=https
  WINRM_PORT="${WINRM_PORT:-5986}"
fi

# The value is used verbatim as a sAMAccountName; reject characters AD does not
# allow before they reach an LDAP filter.
case "$AD_TARGET_USER" in
  *[!a-zA-Z0-9._-]*)
    die "AD_TARGET_USER '${AD_TARGET_USER}' contains characters that are not valid in a sAMAccountName (allowed: letters, digits, dot, underscore, hyphen)" ;;
esac
SAM="$AD_TARGET_USER"

# pywinrm carries the WS-Management plumbing. It ships in the britive/bridge base
# image, so this is a guard against an image that dropped it rather than an
# expected failure -- and it runs up front, so a missing dependency costs nothing.
python3 -c "import winrm" 2>/dev/null \
  || die "pywinrm is not importable on this broker, so the service credential cannot be updated (it ships in the britive/bridge base image; check whether the image was rebuilt from a different base)"


# ------------------------------------------------------------------------------
# The WinRM step runs from a generated python file rather than `python3 -c`.
# Both the PowerShell and the python need literal single quotes, and nesting
# those inside a single-quoted -c string means '"'"' gymnastics that are
# unreviewable and silently mangle a password. A quoted heredoc passes the text
# through untouched.
#
# Written under AD_TMP_DIR, which ad_init creates 0700 and the EXIT trap removes.
# It holds NO secrets: every value arrives as JSON on STDIN at call time.
# ------------------------------------------------------------------------------
write_winrm_helper() {
  WINRM_PY="${AD_TMP_DIR}/winrm_step.py"
  cat > "$WINRM_PY" <<'PYEOF'
import json
import sys

cfg = json.load(sys.stdin)

# The bind password is read from the file ad_init wrote (0600, removed by the EXIT
# trap). ad_init unsets the variable after writing it, so the file is the only
# place it still exists -- and it never passes through argv or an environment.
with open(cfg["password_file"], encoding="utf-8") as handle:
    bind_password = handle.read()

try:
    import winrm
except ImportError:
    sys.stderr.write("pywinrm is not installed\n")
    sys.exit(1)


def ps_quote(value):
    """Render a PowerShell single-quoted literal.

    Only the quote itself needs escaping, and doubling it is the escape. Nothing
    inside such a literal is expanded, so a password containing $, `, " or a
    backslash cannot turn into code.
    """
    return "'" + value.replace("'", "''") + "'"


service = ps_quote(cfg["service"])

if cfg["mode"] == "preflight":
    # Reachability, authentication and the service's existence are all proven by
    # this one call -- deliberately before anything in AD changes.
    script = f"""
$ErrorActionPreference = "Stop"
$svc = Get-Service -Name {service}
Write-Output "service $($svc.Name) found, status $($svc.Status)"
"""
else:
    account = ps_quote(cfg["account"])
    password = ps_quote(cfg["service_password"])
    restart = "$true" if cfg["restart"] else "$false"
    stop_timeout = int(cfg["stop_timeout"])
    start_timeout = int(cfg["start_timeout"])
    script = f"""
$ErrorActionPreference = "Stop"
$svcName = {service}
$svcAccount = {account}

$svc = Get-Service -Name $svcName
Write-Output "found service $($svc.DisplayName) [status $($svc.Status)]"

# Win32_Service.Change() rather than `sc.exe config obj= password=`: sc.exe takes
# the password as a command-line argument, where the remote process table and any
# command-line auditing (Sysmon 1, 4688) both capture it.
# Filtered client-side rather than with -Filter "Name='$svcName'": WQL escaping
# is not PowerShell escaping, so a name containing a quote would break the query
# (or change what it matches). Enumerating a few hundred services costs nothing.
$cim = Get-CimInstance -ClassName Win32_Service | Where-Object {{ $_.Name -eq $svcName }}
if (-not $cim) {{
    throw "no Win32_Service instance named $svcName (Get-Service found it, so this is unexpected)"
}}
$result = Invoke-CimMethod -InputObject $cim -MethodName Change -Arguments @{{
    StartName     = $svcAccount
    StartPassword = {password}
}}
if ($result.ReturnValue -ne 0) {{
    # Change() reports failure in ReturnValue rather than throwing: 2 is Access
    # Denied, 15 Service Database Locked, 22 Invalid Service Account.
    throw "Win32_Service.Change returned $($result.ReturnValue) for $svcName (0 means success)"
}}
Write-Output "service logon account set to $svcAccount"

if (-not {restart}) {{
    Write-Output "restart skipped; the new credential takes effect on the next restart"
    exit 0
}}

Write-Output "stopping $svcName"
Stop-Service -Name $svcName -Force
$waited = 0
while ((Get-Service -Name $svcName).Status -ne "Stopped" -and $waited -lt {stop_timeout}) {{
    Start-Sleep -Seconds 2
    $waited += 2
}}
if ((Get-Service -Name $svcName).Status -ne "Stopped") {{
    throw "$svcName did not stop within {stop_timeout}s"
}}

Write-Output "starting $svcName"
Start-Service -Name $svcName
$waited = 0
while ((Get-Service -Name $svcName).Status -ne "Running" -and $waited -lt {start_timeout}) {{
    Start-Sleep -Seconds 2
    $waited += 2
}}
$final = (Get-Service -Name $svcName).Status
if ($final -ne "Running") {{
    # The usual cause is a bad logon credential: the service fails to start and
    # Windows reports the reason only in the event log.
    throw "$svcName did not reach Running within {start_timeout}s (status $final) -- check the System event log on the target for a logon failure"
}}
Write-Output "service restarted and running"
"""

target = "{}://{}:{}/wsman".format(cfg["scheme"], cfg["host"], cfg["port"])
budget = int(cfg["stop_timeout"]) + int(cfg["start_timeout"])
try:
    session = winrm.Session(
        target=target,
        auth=(cfg["user"], bind_password),
        transport=cfg["transport"],
        # The DC/member server usually presents a self-signed WinRM certificate.
        # HTTP (5985) is the default here and is NOT confidential: NTLM seals the
        # payload, but prefer WINRM_NO_SSL=0 where a certificate exists.
        server_cert_validation="ignore",
        read_timeout_sec=budget + 60,
        operation_timeout_sec=budget + 30,
    )
    result = session.run_ps(script)
except Exception as exc:  # the reason must reach the broker log, whatever it is
    sys.stderr.write("WinRM error against {}: {}\n".format(target, exc))
    sys.exit(1)

out = result.std_out.decode("utf-8", "replace").strip()
err = result.std_err.decode("utf-8", "replace").strip()
for line in out.splitlines():
    sys.stderr.write("  {}\n".format(line))
if result.status_code != 0:
    sys.stderr.write("PowerShell failed (exit {}): {}\n".format(result.status_code, err))
    sys.exit(1)
PYEOF
}

# ------------------------------------------------------------------------------
# winrm_ps <mode> [service_password] — run one PowerShell step on the target.
#
# Everything the step needs arrives as JSON on STDIN, so neither the WinRM
# password nor the new service password ever appears in a command line or in any
# process's environment.
# ------------------------------------------------------------------------------
winrm_ps() {
  local mode="$1" service_password="${2:-}"
  jq -n \
    --arg host "$AD_TARGET_SERVER" \
    --arg user "$WINRM_USER" \
    --arg password_file "$AD_PW_FILE" \
    --arg scheme "$WINRM_SCHEME" \
    --arg transport "$WINRM_TRANSPORT" \
    --argjson port "$WINRM_PORT" \
    --arg mode "$mode" \
    --arg service "$AD_SERVICE_NAME" \
    --arg account "${SERVICE_ACCOUNT:-}" \
    --arg service_password "$service_password" \
    --argjson restart "$RESTART_SERVICE" \
    --argjson stop_timeout "$STOP_TIMEOUT" \
    --argjson start_timeout "$START_TIMEOUT" \
    '$ARGS.named' \
  | python3 "$WINRM_PY"
}

info "rotating '${SAM}' and updating service '${AD_SERVICE_NAME}' on ${AD_TARGET_SERVER}"
info "restart after update: ${RESTART_SERVICE}"

ad_init

# ------------------------------------------------------------------------------
# The account must already exist. A rotation that silently creates its target
# would hand out a credential for an account nobody provisioned.
# ------------------------------------------------------------------------------
USER_DN="$(ad_find_user_dn "$SAM")"
[ -n "$USER_DN" ] \
  || die "account '${SAM}' does not exist in ${AD_BASE_DN} -- this script only rotates existing accounts"
info "resolved '${SAM}' -> ${USER_DN}"

# ------------------------------------------------------------------------------
# DOMAIN\user for the service logon account. A UPN is rejected there.
# ------------------------------------------------------------------------------
# NetBIOS defaults to "britive". It is NOT derivable from the base DN in general --
# the name is set at domain-promotion time and can differ from the first DC= label
# -- so any other domain must set AD_NETBIOS_DOMAIN. Windows compares it
# case-insensitively, so "britive" and "BRITIVE" are the same logon.
NETBIOS="${AD_NETBIOS_DOMAIN:-britive}"
SERVICE_ACCOUNT="${NETBIOS}\\${SAM}"
info "service logon account: ${SERVICE_ACCOUNT}"

# ------------------------------------------------------------------------------
# The WinRM logon name, derived from the AD bind identity.
# ------------------------------------------------------------------------------
# NTLM accepts DOMAIN\user and user@domain but NOT an LDAP distinguished name, and
# AD_SECRET is documented as accepting all three forms. Map the DN case rather than
# failing on it: read the sAMAccountName off that object and pair it with the
# NetBIOS name.
if [ -n "${AD_BIND_WINRM_USER:-}" ]; then
  WINRM_USER="$AD_BIND_WINRM_USER"
else
  case "$AD_BIND_DN" in
    *\\*|*@*)
      # already DOMAIN\user or a UPN; both work for NTLM
      WINRM_USER="$AD_BIND_DN" ;;
    *=*)
      BIND_SAM="$(ad_search "$AD_BIND_DN" base "(objectClass=*)" sAMAccountName | ad_ldif_value sAMAccountName)"
      [ -n "$BIND_SAM" ] \
        || die "the AD bind identity is a distinguished name (${AD_BIND_DN}) and its sAMAccountName could not be read, so no NTLM logon name can be built -- set AD_BIND_WINRM_USER to the DOMAIN\\user form"
      WINRM_USER="${NETBIOS}\\${BIND_SAM}" ;;
    *)
      WINRM_USER="${NETBIOS}\\${AD_BIND_DN}" ;;
  esac
fi
info "WinRM logon: ${WINRM_USER} (the AD bind identity)"

# ------------------------------------------------------------------------------
# Preflight the remote side BEFORE touching AD. See NOTES ON THE PORT: a failure
# after the reset is an outage that cannot be rolled back.
# ------------------------------------------------------------------------------
# Resolve the name first. The broker sits in a VPC that usually does NOT use the
# domain controller for DNS -- these scripts reach the DC by its public EC2 name --
# so an internal AD name like host.contoso.local resolves nowhere from here. Left
# to pywinrm this surfaces as a urllib3 NameResolutionError stack, which reads like
# a WinRM fault rather than the configuration mistake it is.
if ! python3 -c 'import socket, sys; socket.getaddrinfo(sys.argv[1], int(sys.argv[2]))' \
      "$AD_TARGET_SERVER" "$WINRM_PORT" 2>/dev/null; then
  die "AD_TARGET_SERVER '${AD_TARGET_SERVER}' does not resolve from the broker -- nothing was changed in AD. The broker's VPC does not use the domain controller for DNS, so internal AD names do not resolve here. Use the server's private IP or a name the VPC can resolve; NTLM authenticates by name or address alike, unlike Kerberos which would need the FQDN"
fi

write_winrm_helper
info "preflight: checking WinRM ${WINRM_SCHEME}://${AD_TARGET_SERVER}:${WINRM_PORT} and service '${AD_SERVICE_NAME}'"
winrm_ps preflight \
  || die "WinRM preflight FAILED against ${AD_TARGET_SERVER} -- nothing was changed in AD. Check that WinRM is listening, the credential has local admin, and service '${AD_SERVICE_NAME}' exists"
info "preflight OK"

# ------------------------------------------------------------------------------
# Take the new password from the rotation module.
# ------------------------------------------------------------------------------
# Britive's secret rotation module generates the value and injects it as
# AD_NEW_PASSWORD when the attribute is configured on the rotation in the UI.
# This script does NOT generate one: a locally generated password would be known
# only to this process, so the platform could not store or vend it, and the
# rotated credential would be lost the moment the script exited.
NEW_PASSWORD="$AD_NEW_PASSWORD"
# Drop it from the environment so nothing this script spawns inherits it.
unset AD_NEW_PASSWORD
info "using the password supplied by the rotation module (${#NEW_PASSWORD} chars)"

# ------------------------------------------------------------------------------
# Reset in AD, then clear the two flags an administrative reset leaves behind.
# ------------------------------------------------------------------------------
ad_set_password "$USER_DN" "$NEW_PASSWORD" \
  || die "password reset FAILED for '${SAM}' (AD rejected the new password — check the domain password policy, history and minimum-age requirements). The service is untouched and still working"

# Unlock is best-effort: the reset already succeeded, and failing the whole
# rotation over a lockout flag would be worse than reporting it.
ACCOUNT_UNLOCKED=true
if ! ad_unlock_account "$USER_DN"; then
  warn "could not clear lockoutTime on '${SAM}' — if the account was locked out it stays locked"
  ACCOUNT_UNLOCKED=false
fi

# This one is NOT best-effort: an account left flagged must-change cannot
# authenticate non-interactively, so the service could never log on.
ad_clear_must_change_password "$USER_DN" \
  || die "password was reset on '${SAM}' but the must-change-at-next-logon flag could not be cleared -- the service cannot authenticate until it is. THE SERVICE CREDENTIAL WAS NOT UPDATED and the service is now running on a dead password"

info "AD password rotated for '${SAM}'"

# ------------------------------------------------------------------------------
# Write the credential onto the service. From here a failure is an outage: the
# account's old password is gone, so the message has to say so plainly.
# ------------------------------------------------------------------------------
if ! winrm_ps update "$NEW_PASSWORD"; then
  emit username "$SAM"
  emit password_rotated true
  emit account_unlocked "$ACCOUNT_UNLOCKED"
  emit service_updated false
  emit service_restarted false
  if [ "$EMIT_PASSWORD" = "true" ]; then
    emit password "$NEW_PASSWORD"
  fi
  unset NEW_PASSWORD
  die "the AD password WAS rotated but service '${AD_SERVICE_NAME}' on ${AD_TARGET_SERVER} could NOT be updated -- that service is now running on a password that no longer exists and will fail at its next restart. Set the logon credential manually, or re-run this script once WinRM is reachable"
fi

info "rotation complete for '${SAM}'"

emit username "$SAM"
emit password_rotated true
emit account_unlocked "$ACCOUNT_UNLOCKED"
emit service_updated true
emit service_restarted "$RESTART_SERVICE"
if [ "$EMIT_PASSWORD" = "true" ]; then
  emit password "$NEW_PASSWORD"
fi
unset NEW_PASSWORD
