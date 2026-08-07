#!/bin/bash
# ==============================================================================
# Britive rotation: change the underlying credential, THEN update the secret
# ==============================================================================
# For secrets that describe a real account -- a database login, a service
# account, an API principal. Rotating only the secret would leave it advertising
# a password the target never accepted, so this does both, in the one order that
# is recoverable.
#
# Required env vars:
#   AWS_SECRET_ARN     - ARN (or name) of the secret to update
#   AWS_NEW_PASSWORD   - the new value, generated and injected by Britive's
#                        secret rotation module. Never generated here.
#   SECRET_TARGET_HOOK - path to an executable that applies the new password to
#                        the target system (contract below)
#
# Optional env vars:
#   AWS_REGION         - defaults to the region parsed out of the ARN
#   AWS_SECRET_KEY     - JSON key holding the password (default: password)
#   SECRET_USERNAME_KEY- JSON key holding the username (default: username)
#   HOOK_TIMEOUT       - seconds the hook may run (default: 120)
#
# ------------------------------------------------------------------------------
# ORDER OF OPERATIONS AND THE FAILURE WINDOW
# ------------------------------------------------------------------------------
# The TARGET is changed first, the secret second. That leaves a window where the
# account has the new password and the secret still serves the old one, so a
# consumer authenticating in between fails.
#
# The reverse order is worse. The secret would advertise a password the target
# has not accepted yet, and a target that REJECTS the change -- password policy,
# history, minimum age -- would leave the secret permanently wrong with no way to
# tell from the secret alone. The target is the system of record, so it moves
# first and the window is bounded by one API call.
#
# If the secret write fails after the target changed, this exits NON-ZERO and says
# plainly that the two have diverged, naming both. That is a real operational
# break needing a manual fix; it is never reported as success.
#
# ------------------------------------------------------------------------------
# THE HOOK CONTRACT
# ------------------------------------------------------------------------------
# SECRET_TARGET_HOOK is an executable this script runs once. It is how a
# particular target system gets taught about the new password without this script
# knowing anything about that system.
#
#   receives   the new password on STDIN, and nothing else. Not argv (visible in
#              /proc/<pid>/cmdline), not the environment (inherited by anything
#              the hook spawns).
#
#   environment  SECRET_ARN, SECRET_NAME, SECRET_USERNAME, AWS_REGION, plus every
#                RESOURCE_* attribute already in scope. No password among them.
#
#   exit 0     the target accepted the new password and it is live NOW. Only then
#              is the secret updated.
#   exit != 0  nothing is written to the secret. The hook's stderr (first 500
#              characters) is included in the failure message, so it should say
#              what went wrong on stderr.
#
# A hook must be idempotent: a rotation retried after a lost response will run it
# again with the same password.
#
# Example hook, PostgreSQL:
#
#   #!/bin/bash
#   set -euo pipefail
#   read -r NEW_PW
#   export PGPASSWORD_FILE=...
#   psql -h "$DB_HOST" -U admin -d postgres -v ON_ERROR_STOP=1 \
#     -c "ALTER ROLE \"${SECRET_USERNAME}\" WITH PASSWORD '${NEW_PW//\'/\'\'}'"
#
# For Active Directory this whole script is unnecessary:
# ../../active-directory/rotate/rotate-ad-account-aws-secret.sh already does both
# phases natively over LDAPS.
#
# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------
#   secretsmanager:GetSecretValue, secretsmanager:PutSecretValue on the secret
#   kms:Decrypt, kms:GenerateDataKey if it uses a customer-managed key
# ==============================================================================

set -uo pipefail

LOG_TAG="sm-rotate-target"
TRACE=""
DIED=""

info() {
  if [ "${ROTATE_VERBOSE:-false}" = "true" ]; then
    printf '%s [%s] INFO  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_TAG" "$1" >&2
  else
    TRACE="${TRACE}${1}; "
  fi
}

warn() {
  printf '%s [%s] WARN  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_TAG" "$*" >&2
}

die() {
  DIED=1
  printf '%s [%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_TAG" "$*" >&2
  [ -n "$TRACE" ] && printf 'trace: %s\n' "$TRACE" >&2
  exit 1
}

emit() { printf '%s=%s\n' "$1" "$2"; }

TMP_DIR=""
cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$DIED" ]; then
    printf 'exited %s without a reason; trace: %s\n' "$rc" "${TRACE:-<empty>}" >&2
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    find "$TMP_DIR" -type f -exec sh -c \
      'dd if=/dev/zero of="$1" bs=1 count="$(wc -c < "$1" | tr -d " ")" conv=notrunc 2>/dev/null' _ {} \; 2>/dev/null
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Inputs.
# ------------------------------------------------------------------------------
SECRET_ARN="${AWS_SECRET_ARN:-${RESOURCE_AWS_SECRET_ARN:-}}"
REGION="${AWS_REGION:-${RESOURCE_AWS_REGION:-}}"
SECRET_KEY="${AWS_SECRET_KEY:-password}"
USERNAME_KEY="${SECRET_USERNAME_KEY:-username}"
HOOK="${SECRET_TARGET_HOOK:-}"
HOOK_TIMEOUT="${HOOK_TIMEOUT:-120}"

[ -n "$SECRET_ARN" ] \
  || die "no target secret: set AWS_SECRET_ARN on the rotation (the scan records each secret's ARN as its identity id)"
[ -n "${AWS_NEW_PASSWORD:-}" ] \
  || die "AWS_NEW_PASSWORD is not set. Britive's rotation module supplies it; configure the attribute on the rotation in the UI. This script does not generate passwords."
[ -n "$HOOK" ] \
  || die "SECRET_TARGET_HOOK is not set. Without it the target system would never learn the new password and the secret would advertise a credential that does not work. Use rotate-secret-value.sh if the secret really is the system of record."

if [ -z "$REGION" ]; then
  case "$SECRET_ARN" in
    arn:*:secretsmanager:*)
      REGION="$(printf '%s' "$SECRET_ARN" | cut -d: -f4)" ;;
  esac
fi
[ -n "$REGION" ] \
  || die "no region: pass a full secret ARN, or set the resource's AWS_REGION attribute (arrives as RESOURCE_AWS_REGION)"
export AWS_REGION="$REGION"

for cmd in aws jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "broker is missing required command: ${cmd}"
done

# The hook runs with this script's credentials, so a hook someone else can edit is
# a hook someone else can run as the broker.
[ -f "$HOOK" ] || die "SECRET_TARGET_HOOK '${HOOK}' is not a file"
[ -x "$HOOK" ] || die "SECRET_TARGET_HOOK '${HOOK}' is not executable"
if [ -n "$(find "$HOOK" -perm -o+w 2>/dev/null)" ]; then
  die "SECRET_TARGET_HOOK '${HOOK}' is world-writable; anything in this container could replace it and have it run with the broker's credentials"
fi

TMP_DIR="$(mktemp -d)" || die "mktemp -d failed (no writable TMPDIR?)"
chmod 700 "$TMP_DIR"

NEW_VALUE="$AWS_NEW_PASSWORD"
unset AWS_NEW_PASSWORD
info "rotating '${SECRET_ARN}' in ${REGION} via hook ${HOOK} (${#NEW_VALUE} chars)"

# ------------------------------------------------------------------------------
# Validate BOTH sides before touching either. Discovering the secret is unwritable
# after the target has already changed is the divergence this avoids.
# ------------------------------------------------------------------------------
DESCRIBE_JSON="${TMP_DIR}/describe.json"
aws secretsmanager describe-secret --secret-id "$SECRET_ARN" --region "$REGION" \
    --output json > "$DESCRIBE_JSON" 2>"${TMP_DIR}/describe.err" \
  || die "cannot describe secret '${SECRET_ARN}' in ${REGION}: $(tr '\n' ' ' < "${TMP_DIR}/describe.err" | cut -c1-200)"

SECRET_NAME="$(jq -r '.Name // empty' < "$DESCRIBE_JSON")"
OWNING_SERVICE="$(jq -r '.OwningService // empty' < "$DESCRIBE_JSON")"
DELETED_DATE="$(jq -r '.DeletedDate // empty' < "$DESCRIBE_JSON")"

[ -z "$DELETED_DATE" ] \
  || die "secret '${SECRET_NAME}' is scheduled for deletion (${DELETED_DATE}); restore it before rotating"
if [ -n "$OWNING_SERVICE" ] && [ "${ALLOW_SERVICE_OWNED:-false}" != "true" ]; then
  die "secret '${SECRET_NAME}' is owned by ${OWNING_SERVICE}, which rotates it itself. Rotate it through ${OWNING_SERVICE}, or set ALLOW_SERVICE_OWNED=true if you are certain."
fi

CURRENT_FILE="${TMP_DIR}/current.json"
aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" \
    --version-stage AWSCURRENT --query SecretString --output text \
    > "$CURRENT_FILE" 2>"${TMP_DIR}/get.err" \
  || die "cannot read secret '${SECRET_NAME}' (check secretsmanager:GetSecretValue, and kms:Decrypt for a customer-managed key): $(tr '\n' ' ' < "${TMP_DIR}/get.err" | cut -c1-200)"
chmod 600 "$CURRENT_FILE"
printf '%s' "$(cat "$CURRENT_FILE")" > "${CURRENT_FILE}.raw" && mv "${CURRENT_FILE}.raw" "$CURRENT_FILE"

# A JSON object is required here, unlike rotate-secret-value.sh: an account
# rotation needs a username to tell the hook WHICH account to change, and a
# plaintext secret has nowhere to keep one.
jq -e 'type == "object"' < "$CURRENT_FILE" >/dev/null 2>&1 \
  || die "secret '${SECRET_NAME}' is not a JSON object. A target rotation needs the account name alongside the password; a plaintext secret cannot carry one. Use rotate-secret-value.sh, or convert the secret to {\"${USERNAME_KEY}\": ..., \"${SECRET_KEY}\": ...}."

TARGET_USERNAME="$(jq -r --arg k "$USERNAME_KEY" '.[$k] // empty' < "$CURRENT_FILE")"
[ -n "$TARGET_USERNAME" ] \
  || die "secret '${SECRET_NAME}' has no '${USERNAME_KEY}' key, so there is no account for the hook to change. Set SECRET_USERNAME_KEY if it is stored under a different name."

jq -e --arg k "$SECRET_KEY" 'has($k)' < "$CURRENT_FILE" >/dev/null 2>&1 \
  || warn "secret '${SECRET_NAME}' has no '${SECRET_KEY}' key yet; it will be added"

# Build the patched JSON NOW, before the hook runs: a jq or encoding failure here
# is harmless, whereas the same failure after the target changed means divergence.
STAGED="${TMP_DIR}/staged.json"
( umask 077; jq --arg k "$SECRET_KEY" --arg v "$NEW_VALUE" '.[$k] = $v' < "$CURRENT_FILE" > "$STAGED" ) \
  || die "could not build the patched secret JSON"
chmod 600 "$STAGED"
printf '%s' "$NEW_VALUE" | jq -Rs --slurpfile new "$STAGED" --arg k "$SECRET_KEY" \
  -e '($new[0][$k]) == .' >/dev/null 2>&1 \
  || die "the staged JSON does not contain the new value under '${SECRET_KEY}'"
info "staged the patched secret, keys: $(jq -r 'keys | join(", ")' < "$STAGED")"

# ------------------------------------------------------------------------------
# 1. The target (system of record).
# ------------------------------------------------------------------------------
# The password goes in on stdin only. Passing it in argv would put it in
# /proc/<pid>/cmdline; passing it in the environment would hand it to everything
# the hook spawns.
HOOK_ERR="${TMP_DIR}/hook.err"
HOOK_OUT="${TMP_DIR}/hook.out"

TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout"

info "running the target hook for account '${TARGET_USERNAME}'"
if [ -n "$TIMEOUT_BIN" ]; then
  printf '%s' "$NEW_VALUE" | env \
    SECRET_ARN="$SECRET_ARN" SECRET_NAME="$SECRET_NAME" \
    SECRET_USERNAME="$TARGET_USERNAME" AWS_REGION="$REGION" \
    "$TIMEOUT_BIN" "$HOOK_TIMEOUT" "$HOOK" > "$HOOK_OUT" 2> "$HOOK_ERR"
else
  warn "no timeout(1) in this image; the hook runs unbounded"
  printf '%s' "$NEW_VALUE" | env \
    SECRET_ARN="$SECRET_ARN" SECRET_NAME="$SECRET_NAME" \
    SECRET_USERNAME="$TARGET_USERNAME" AWS_REGION="$REGION" \
    "$HOOK" > "$HOOK_OUT" 2> "$HOOK_ERR"
fi
HOOK_RC=$?

if [ "$HOOK_RC" -eq 124 ]; then
  die "target hook TIMED OUT after ${HOOK_TIMEOUT}s for account '${TARGET_USERNAME}'. The secret was NOT modified, but the hook may have partially applied the change -- verify '${TARGET_USERNAME}' before retrying."
fi
if [ "$HOOK_RC" -ne 0 ]; then
  die "target hook FAILED (exit ${HOOK_RC}) for account '${TARGET_USERNAME}': $(tr '\n' ' ' < "$HOOK_ERR" | cut -c1-500). The secret was NOT modified, so the target and Secrets Manager are still consistent."
fi
info "target hook accepted the new password for '${TARGET_USERNAME}'"

# ------------------------------------------------------------------------------
# 2. Secrets Manager. From here a failure means the two systems disagree.
# ------------------------------------------------------------------------------
REQUEST_TOKEN="$(python3 -c 'import uuid; print(uuid.uuid4())')" \
  || die "could not generate a client request token"

if ! NEW_VERSION="$(aws secretsmanager put-secret-value \
      --secret-id "$SECRET_ARN" \
      --region "$REGION" \
      --secret-string "file://${STAGED}" \
      --client-request-token "$REQUEST_TOKEN" \
      --query VersionId --output text 2>&1)"; then
  die "DIVERGED: account '${TARGET_USERNAME}' now has the NEW password but secret '${SECRET_NAME}' still holds the OLD one, so every consumer reading that secret will fail to authenticate. PutSecretValue said: ${NEW_VERSION//$'\n'/ }. Re-run once the secret is writable, or set '${TARGET_USERNAME}' back to the value still in the secret."
fi
info "wrote version ${NEW_VERSION}"

# ------------------------------------------------------------------------------
# Verify the secret consumers will actually read.
# ------------------------------------------------------------------------------
VERIFY_FILE="${TMP_DIR}/verify.json"
if ! aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" \
      --version-stage AWSCURRENT --query SecretString --output text \
      > "$VERIFY_FILE" 2>"${TMP_DIR}/verify.err"; then
  die "DIVERGENCE UNVERIFIED: '${TARGET_USERNAME}' was rotated and version ${NEW_VERSION} was written, but reading the secret back failed: $(tr '\n' ' ' < "${TMP_DIR}/verify.err" | cut -c1-200)"
fi
chmod 600 "$VERIFY_FILE"
printf '%s' "$(cat "$VERIFY_FILE")" > "${VERIFY_FILE}.raw" && mv "${VERIFY_FILE}.raw" "$VERIFY_FILE"

printf '%s' "$NEW_VALUE" | jq -Rs --slurpfile cur "$VERIFY_FILE" --arg k "$SECRET_KEY" \
  -e '($cur[0][$k]) == .' >/dev/null 2>&1 \
  || die "DIVERGED: '${TARGET_USERNAME}' has the new password but AWSCURRENT on '${SECRET_NAME}' does not carry it under '${SECRET_KEY}', even after version ${NEW_VERSION} was written."
info "verified AWSCURRENT carries the new value"

unset NEW_VALUE

emit secret_arn "$SECRET_ARN"
emit secret_name "$SECRET_NAME"
emit region "$REGION"
emit username "$TARGET_USERNAME"
emit secret_key "$SECRET_KEY"
emit target_hook "$HOOK"
emit new_version "$NEW_VERSION"
emit rotated true
emit verified true
