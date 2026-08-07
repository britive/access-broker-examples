#!/bin/bash
# ==============================================================================
# Britive AD rotation: reset the password on a named account
# ==============================================================================
# Port of rotate/rotate-ad-account.ps1 to run on the Linux Britive Bridge broker
# (Alpine container) instead of a Windows host with RSAT.
#
# Resets the password on an account the profile names explicitly, unlocks it, and
# clears the must-change-password-at-next-logon flag that an administrative reset
# otherwise leaves behind.
#
# This is a ROTATION script, not a checkout/checkin pair. It never derives a name
# from the requester's email and never creates an account: the target is named
# outright, because it is shared infrastructure rather than one person's admin
# identity.
#
# Required env vars:
#   AD_TARGET_USER   - sAMAccountName of the account to rotate, e.g. svc-app01
#   AD_NEW_PASSWORD  - the new password. Britive's secret rotation module
#                      generates it and injects it when the attribute is
#                      configured on the rotation in the UI. This script never
#                      generates one -- see NOTES ON THE PORT.
#
# Connection env vars: see lib/ad_common.sh.
#
# Optional env vars:
#   AD_EMIT_PASSWORD   - "true" to print the password on STDOUT for a response
#                        template. Default false: a rotation that nobody is told
#                        about is the safe default, and the original never
#                        emitted it.
#
# Output (STDOUT): username / password_rotated / account_unlocked
#                  (plus password when AD_EMIT_PASSWORD=true)
#
# ------------------------------------------------------------------------------
# NOTES ON THE PORT
# ------------------------------------------------------------------------------
#   * Unlock-ADAccount has no LDAP equivalent; it is a lockoutTime=0 write.
#   * Set-ADUser -ChangePasswordAtLogon $false is a pwdLastSet=-1 write.
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

AD_LOG_TAG="ad-rotate-account"

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

ad_require_vars AD_TARGET_USER AD_NEW_PASSWORD

EMIT_PASSWORD="${AD_EMIT_PASSWORD:-false}"

# The value is used verbatim as a sAMAccountName; reject characters AD does not
# allow before they reach an LDAP filter.
case "$AD_TARGET_USER" in
  *[!a-zA-Z0-9._-]*)
    die "AD_TARGET_USER '${AD_TARGET_USER}' contains characters that are not valid in a sAMAccountName (allowed: letters, digits, dot, underscore, hyphen)" ;;
esac

SAM="$AD_TARGET_USER"
info "rotating password for account '${SAM}'"

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
# Reset, then clear the two flags an administrative reset leaves behind.
# ------------------------------------------------------------------------------
ad_set_password "$USER_DN" "$NEW_PASSWORD" \
  || die "password reset FAILED for '${SAM}' (AD rejected the new password — check the domain password policy, history and minimum-age requirements)"

# Unlock is best-effort: the reset already succeeded, and failing the whole
# rotation over a lockout flag would be worse than reporting it.
ACCOUNT_UNLOCKED=true
if ! ad_unlock_account "$USER_DN"; then
  warn "could not clear lockoutTime on '${SAM}' — if the account was locked out it stays locked"
  ACCOUNT_UNLOCKED=false
fi

# This one is NOT best-effort: an account left flagged must-change cannot
# authenticate non-interactively, so the rotated credential would be useless.
ad_clear_must_change_password "$USER_DN" \
  || die "password was reset on '${SAM}' but the must-change-at-next-logon flag could not be cleared -- the account cannot authenticate non-interactively until it is"

info "rotation complete for '${SAM}'"

emit username "$SAM"
emit password_rotated true
emit account_unlocked "$ACCOUNT_UNLOCKED"
if [ "$EMIT_PASSWORD" = "true" ]; then
  emit password "$NEW_PASSWORD"
fi
unset NEW_PASSWORD
