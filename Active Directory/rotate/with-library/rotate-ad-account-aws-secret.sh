#!/bin/bash
# ==============================================================================
# Britive AD rotation: reset an account password and sync it to Secrets Manager
# ==============================================================================
# Port of rotate/rotate-ad-account-aws-secret.ps1 to run on the Linux Britive
# Bridge broker (Alpine container) instead of a Windows host with RSAT.
#
# Resets the password in AD, then patches ONE key of an existing Secrets Manager
# secret so downstream consumers pick the new value up. Every other field in the
# secret (username, host, port, ...) is preserved.
#
# Required env vars:
#   AD_TARGET_USER  - sAMAccountName of the account to rotate
#   AWS_SECRET_ARN  - ARN (or name) of the Secrets Manager secret to patch
#
#   AD_NEW_PASSWORD  - the new password. Britive's secret rotation module
#                      generates it and injects it when the attribute is
#                      configured on the rotation in the UI. This script never
#                      generates one -- see NOTES ON THE PORT.
#
# Connection env vars: see lib/ad_common.sh.
#
# Optional env vars:
#   AWS_SECRET_KEY     - JSON key holding the password (default: password)
#
# The task role needs secretsmanager:GetSecretValue AND
# secretsmanager:PutSecretValue on the target secret, plus kms:Decrypt and
# kms:GenerateDataKey if it uses a customer-managed key.
#
# ------------------------------------------------------------------------------
# ORDER OF OPERATIONS AND THE FAILURE WINDOW
# ------------------------------------------------------------------------------
# AD is updated FIRST, then the secret — same as the original. That leaves a
# window where AD has the new password and the secret still has the old one, so a
# consumer authenticating in between fails.
#
# Reversing the order would be worse: the secret would advertise a password that
# AD has not accepted yet, and a rejected AD reset (password policy, history,
# minimum age) would leave the secret permanently wrong. AD is the system of
# record, so it moves first.
#
# If the secret write fails the script exits NON-ZERO and says plainly that AD
# and the secret have diverged, naming the account and the secret. That is a
# genuine operational break requiring a manual fix; it is never reported as
# success.
#
# ------------------------------------------------------------------------------
# WHAT THE POWERSHELL ORIGINAL WORKED AROUND AND THIS DOES NOT NEED
# ------------------------------------------------------------------------------
#   * aws.exe path hunting through Program Files — `aws` is on PATH in this image.
#   * UTF-8 BOM corruption — a PowerShell 5.1 encoding default. Not applicable.
#   * `<` unescaping — ConvertTo-Json escapes < > & '. python's json does not.
#   * SecureString disposal / variable zeroing — no managed-memory equivalent in
#     bash. Instead the plaintext never reaches a command line or the environment
#     of a child process, and the temp file is shredded.
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

AD_LOG_TAG="ad-rotate-aws-secret"

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

ad_require_vars AD_TARGET_USER AWS_SECRET_ARN AD_NEW_PASSWORD
ad_require_cmds aws jq

SECRET_KEY="${AWS_SECRET_KEY:-password}"

case "$AD_TARGET_USER" in
  *[!a-zA-Z0-9._-]*)
    die "AD_TARGET_USER '${AD_TARGET_USER}' contains characters that are not valid in a sAMAccountName (allowed: letters, digits, dot, underscore, hyphen)" ;;
esac

SAM="$AD_TARGET_USER"
info "rotating '${SAM}' and syncing key '${SECRET_KEY}' in secret '${AWS_SECRET_ARN}'"

ad_init

# ------------------------------------------------------------------------------
# Validate BOTH systems before touching either. Discovering the secret is
# unreadable after AD has already been reset is the divergence this avoids.
# ------------------------------------------------------------------------------
USER_DN="$(ad_find_user_dn "$SAM")"
[ -n "$USER_DN" ] \
  || die "account '${SAM}' does not exist in ${AD_BASE_DN} -- this script only rotates existing accounts"
info "resolved '${SAM}' -> ${USER_DN}"

info "reading the current secret value"
CURRENT_SECRET="$(aws secretsmanager get-secret-value \
    --secret-id "$AWS_SECRET_ARN" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text)" \
  || die "cannot read secret '${AWS_SECRET_ARN}' in ${AWS_REGION} (check the ARN and that the task role holds secretsmanager:GetSecretValue)"

# The secret must be a JSON object: this script patches one key and preserves the
# rest, which is meaningless for a plaintext secret. Refuse rather than replace
# the whole value and destroy the other fields.
printf '%s' "$CURRENT_SECRET" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || die "secret '${AWS_SECRET_ARN}' is not a JSON object -- this script patches the '${SECRET_KEY}' key of a JSON secret and will not overwrite a plaintext value"

if ! printf '%s' "$CURRENT_SECRET" | jq -e --arg k "$SECRET_KEY" 'has($k)' >/dev/null 2>&1; then
  warn "secret '${AWS_SECRET_ARN}' has no '${SECRET_KEY}' key yet; it will be added"
fi
info "secret is a JSON object with keys: $(printf '%s' "$CURRENT_SECRET" | jq -r 'keys | join(", ")')"

# ------------------------------------------------------------------------------
# Staging for the new secret value. Passing --secret-string on the command line
# would expose the plaintext in /proc/<pid>/cmdline, so it goes to a 0600 file
# referenced as file://.
# ------------------------------------------------------------------------------
SECRET_FILE="${AD_TMP_DIR}/secret.json"

# Shred before delete: the EXIT trap in the library removes AD_TMP_DIR, but
# overwriting first shrinks the window for on-disk recovery. Mirrors the
# zero-then-delete the PowerShell original did.
shred_secret_file() {
  if [ -f "$SECRET_FILE" ]; then
    dd if=/dev/zero of="$SECRET_FILE" bs=1 \
       count="$(wc -c < "$SECRET_FILE" | tr -d ' ')" conv=notrunc 2>/dev/null || true
    rm -f "$SECRET_FILE"
  fi
}
trap 'ad_trace_exit_trap; shred_secret_file; ad_cleanup' EXIT INT TERM

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

# Build the patched JSON now, BEFORE touching AD: a jq/encoding failure here is
# harmless, whereas the same failure after the AD reset would mean divergence.
# --arg passes the password as data, so no quoting or escaping can corrupt it.
printf '%s' "$CURRENT_SECRET" \
  | jq --arg k "$SECRET_KEY" --arg v "$NEW_PASSWORD" '.[$k] = $v' > "$SECRET_FILE" \
  || die "could not build the patched secret JSON"
chmod 600 "$SECRET_FILE"

# Prove the staged file is valid JSON carrying the new value, without printing it.
printf '%s' "$NEW_PASSWORD" | jq -Rs --slurpfile new "$SECRET_FILE" --arg k "$SECRET_KEY" \
  -e '($new[0][$k]) == .' >/dev/null 2>&1 \
  || die "the staged secret JSON does not contain the new password under '${SECRET_KEY}'"
info "staged the patched secret ($(wc -c < "$SECRET_FILE" | tr -d ' ') bytes)"

# ------------------------------------------------------------------------------
# 1. AD (system of record)
# ------------------------------------------------------------------------------
ad_set_password "$USER_DN" "$NEW_PASSWORD" \
  || die "password reset FAILED for '${SAM}' (AD rejected the new password — check the domain password policy, history and minimum-age requirements). The secret was NOT modified, so AD and Secrets Manager are still consistent."

ACCOUNT_UNLOCKED=true
if ! ad_unlock_account "$USER_DN"; then
  warn "could not clear lockoutTime on '${SAM}' — if the account was locked out it stays locked"
  ACCOUNT_UNLOCKED=false
fi

ad_clear_must_change_password "$USER_DN" \
  || die "password was reset on '${SAM}' but the must-change-at-next-logon flag could not be cleared -- the account cannot authenticate non-interactively. Secrets Manager has NOT been updated, so it still holds the previous password."

info "AD updated for '${SAM}'"

# ------------------------------------------------------------------------------
# 2. Secrets Manager. From here a failure means the two systems disagree.
# ------------------------------------------------------------------------------
if ! NEW_VERSION="$(aws secretsmanager put-secret-value \
      --secret-id "$AWS_SECRET_ARN" \
      --region "$AWS_REGION" \
      --secret-string "file://${SECRET_FILE}" \
      --query VersionId --output text 2>&1)"; then
  error "Secrets Manager update FAILED: ${NEW_VERSION//$'\n'/ }"
  die "DIVERGED: AD account '${SAM}' now has the NEW password but secret '${AWS_SECRET_ARN}' still holds the OLD one. Consumers reading that secret will fail to authenticate. Re-run this script once the secret is writable, or reset '${SAM}' back to the value in the secret."
fi

info "Secrets Manager updated (version ${NEW_VERSION})"
info "rotation complete for '${SAM}'"

# The password itself is never emitted: the whole point of this flow is that
# consumers read it from Secrets Manager.
emit username "$SAM"
emit password_rotated true
emit account_unlocked "$ACCOUNT_UNLOCKED"
emit secret_arn "$AWS_SECRET_ARN"
emit secret_key "$SECRET_KEY"
emit secret_version "$NEW_VERSION"
unset NEW_PASSWORD
