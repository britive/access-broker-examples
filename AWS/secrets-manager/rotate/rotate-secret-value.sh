#!/bin/bash
# ==============================================================================
# Britive rotation: write a new value into an AWS Secrets Manager secret
# ==============================================================================
# Takes the password Britive's secret rotation module generated and stores it in
# a Secrets Manager secret, then verifies it landed.
#
# Required env vars:
#   AWS_SECRET       - the secret to rotate: its NAME or its full ARN, either one.
#                      Passed straight to --secret-id, which accepts both. The
#                      scan publishes the name as the identity id and the ARN in
#                      the secret_arn attribute, so whichever is to hand works.
#   AWS_NEW_PASSWORD - the new value. Britive's rotation module generates it and
#                      injects it when the attribute is configured on the
#                      rotation in the UI. This script never generates one.
#
# Optional env vars:
#   AWS_REGION      - required when AWS_SECRET is a name; with a full ARN the
#                     region is read out of the ARN instead
#   AWS_SECRET_KEY  - JSON key to patch (default: password)
#   AWS_SECRET_MODE - auto | json-key | plaintext (default: auto)
#
# The broker also injects the resource's attributes as RESOURCE_AWS_REGION and
# friends; those are read below as fallbacks.
#
# ------------------------------------------------------------------------------
# SCOPE: THIS ROTATES THE SECRET, NOT WHAT THE SECRET DESCRIBES
# ------------------------------------------------------------------------------
# After this runs, the secret advertises a new password. Nothing else changed.
# If a database or directory account sits behind the secret, that account still
# has the OLD password and every consumer reading the secret will now fail to
# authenticate.
#
# Use this script when the secret IS the system of record -- an API key, a shared
# token, a value some other process consumes and re-registers.
#
# When a real account sits behind it, use rotate-secret-with-target.sh (which
# changes the account first and the secret second), or the purpose-built
# ../../active-directory/rotate/rotate-ad-account-aws-secret.sh for AD.
#
# ------------------------------------------------------------------------------
# MODES
# ------------------------------------------------------------------------------
#   auto       inspect the current value: a JSON object is patched at
#              AWS_SECRET_KEY and every other field preserved; anything else is
#              replaced wholesale. This is the default and is what you want.
#   json-key   require a JSON object; refuse a plaintext secret rather than
#              overwrite it.
#   plaintext  replace the whole value, whatever it currently is. Destructive on
#              a JSON secret -- every other field is lost -- so it must be asked
#              for by name.
#
# ------------------------------------------------------------------------------
# ROLLBACK IS ALREADY THERE
# ------------------------------------------------------------------------------
# PutSecretValue moves the AWSCURRENT staging label to the new version and demotes
# the previous one to AWSPREVIOUS. The old value therefore survives a bad
# rotation with no backup step of our own:
#
#   aws secretsmanager get-secret-value --secret-id <arn> --version-stage AWSPREVIOUS
#
# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------
#   secretsmanager:GetSecretValue, secretsmanager:PutSecretValue on the secret
#   kms:Decrypt, kms:GenerateDataKey if it uses a customer-managed key
# ==============================================================================

set -uo pipefail

LOG_TAG="sm-rotate-value"
TRACE=""
DIED=""

# INFO is buffered and the error prints FIRST: Britive keeps only about the first
# 250 characters of the captured output and CloudWatch holds nothing more, so a
# run that logs progress first has its actual failure truncated away.
# ROTATE_VERBOSE=true restores live logging.
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
  # Shred before delete: overwriting first shrinks the window for on-disk
  # recovery of the plaintext staged for PutSecretValue.
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    find "$TMP_DIR" -type f -exec sh -c \
      'dd if=/dev/zero of="$1" bs=1 count="$(wc -c < "$1" | tr -d " ")" conv=notrunc 2>/dev/null' _ {} \; 2>/dev/null
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Inputs. Plain assignment, no name guessing.
# ------------------------------------------------------------------------------
SECRET_ID="${AWS_SECRET:-${RESOURCE_AWS_SECRET:-}}"
REGION="${AWS_REGION:-${RESOURCE_AWS_REGION:-}}"
SECRET_KEY="${AWS_SECRET_KEY:-password}"
SECRET_MODE="${AWS_SECRET_MODE:-auto}"

[ -n "$SECRET_ID" ] \
  || die "no target secret: set AWS_SECRET on the rotation. Either the secret's name or its full ARN works; the scan records the name as the identity id and the ARN in the secret_arn attribute."
[ -n "${AWS_NEW_PASSWORD:-}" ] \
  || die "AWS_NEW_PASSWORD is not set. Britive's rotation module supplies it; configure the attribute on the rotation in the UI. This script does not generate passwords -- one generated here would exist only in this process, so the platform could neither store nor vend it and the rotated credential would be lost on exit."

case "$SECRET_MODE" in
  auto|json-key|plaintext) ;;
  *) die "AWS_SECRET_MODE '${SECRET_MODE}' is not one of: auto, json-key, plaintext" ;;
esac

# An ARN carries its own region, so deriving it beats requiring it twice and
# getting the two out of step.
if [ -z "$REGION" ]; then
  case "$SECRET_ID" in
    arn:*:secretsmanager:*)
      REGION="$(printf '%s' "$SECRET_ID" | cut -d: -f4)" ;;
  esac
fi
[ -n "$REGION" ] \
  || die "no region: pass a full secret ARN, or set the resource's AWS_REGION attribute (arrives as RESOURCE_AWS_REGION)"
export AWS_REGION="$REGION"

for cmd in aws jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "broker is missing required command: ${cmd}"
done

TMP_DIR="$(mktemp -d)" || die "mktemp -d failed (no writable TMPDIR?)"
chmod 700 "$TMP_DIR"

info "rotating secret '${SECRET_ID}' in ${REGION}, mode ${SECRET_MODE}"

# Take the value out of the environment so nothing this script spawns inherits it.
NEW_VALUE="$AWS_NEW_PASSWORD"
unset AWS_NEW_PASSWORD
info "using the value supplied by the rotation module (${#NEW_VALUE} chars)"

# ------------------------------------------------------------------------------
# Describe first. A secret owned by another AWS service has its own rotation
# machinery, and writing to it here leaves that service holding a password its
# own records say is different.
# ------------------------------------------------------------------------------
DESCRIBE_JSON="${TMP_DIR}/describe.json"
if ! aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" \
      --output json > "$DESCRIBE_JSON" 2>"${TMP_DIR}/describe.err"; then
  die "cannot describe secret '${SECRET_ID}' in ${REGION}: $(tr '\n' ' ' < "${TMP_DIR}/describe.err" | cut -c1-200)"
fi

SECRET_NAME="$(jq -r '.Name // empty' < "$DESCRIBE_JSON")"
# AWS_SECRET may have been a name, so take the canonical ARN from the API rather
# than echoing back whatever was passed in.
SECRET_FULL_ARN="$(jq -r '.ARN // empty' < "$DESCRIBE_JSON")"
OWNING_SERVICE="$(jq -r '.OwningService // empty' < "$DESCRIBE_JSON")"
DELETED_DATE="$(jq -r '.DeletedDate // empty' < "$DESCRIBE_JSON")"
NATIVE_ROTATION="$(jq -r '.RotationEnabled // false' < "$DESCRIBE_JSON")"

[ -z "$DELETED_DATE" ] \
  || die "secret '${SECRET_NAME}' is scheduled for deletion (${DELETED_DATE}); restore it before rotating"

if [ -n "$OWNING_SERVICE" ]; then
  if [ "${ALLOW_SERVICE_OWNED:-false}" = "true" ]; then
    warn "secret '${SECRET_NAME}' is owned by ${OWNING_SERVICE}; proceeding because ALLOW_SERVICE_OWNED=true"
  else
    die "secret '${SECRET_NAME}' is owned by ${OWNING_SERVICE}, which rotates it itself. Writing a value here desynchronises that service from its own credential. Rotate it through ${OWNING_SERVICE}, or set ALLOW_SERVICE_OWNED=true if you are certain."
  fi
fi

if [ "$NATIVE_ROTATION" = "true" ]; then
  warn "secret '${SECRET_NAME}' also has AWS-native rotation enabled; the next Lambda run will overwrite what this rotation writes"
fi

# ------------------------------------------------------------------------------
# Read the current value and decide the shape. Doing this BEFORE the write means
# an unreadable or unexpectedly-shaped secret costs nothing.
# ------------------------------------------------------------------------------
CURRENT_FILE="${TMP_DIR}/current.json"
if ! aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
      --version-stage AWSCURRENT --query SecretString --output text \
      > "$CURRENT_FILE" 2>"${TMP_DIR}/get.err"; then
  die "cannot read secret '${SECRET_NAME}' in ${REGION} (check secretsmanager:GetSecretValue, and kms:Decrypt if it uses a customer-managed key): $(tr '\n' ' ' < "${TMP_DIR}/get.err" | cut -c1-200)"
fi
chmod 600 "$CURRENT_FILE"

# --output text appends a newline that is not part of the value; strip exactly one.
printf '%s' "$(cat "$CURRENT_FILE")" > "${CURRENT_FILE}.raw" && mv "${CURRENT_FILE}.raw" "$CURRENT_FILE"

IS_JSON_OBJECT=false
if jq -e 'type == "object"' < "$CURRENT_FILE" >/dev/null 2>&1; then
  IS_JSON_OBJECT=true
fi

EFFECTIVE_MODE="$SECRET_MODE"
if [ "$SECRET_MODE" = "auto" ]; then
  if [ "$IS_JSON_OBJECT" = "true" ]; then EFFECTIVE_MODE="json-key"; else EFFECTIVE_MODE="plaintext"; fi
  info "auto mode resolved to ${EFFECTIVE_MODE}"
fi

if [ "$EFFECTIVE_MODE" = "json-key" ] && [ "$IS_JSON_OBJECT" != "true" ]; then
  die "secret '${SECRET_NAME}' is not a JSON object, so key '${SECRET_KEY}' cannot be patched. Set AWS_SECRET_MODE=plaintext to replace the whole value instead."
fi

# ------------------------------------------------------------------------------
# Stage the new value in a 0600 file. Passing --secret-string on the command line
# would expose the plaintext in /proc/<pid>/cmdline to everything in the
# container.
# ------------------------------------------------------------------------------
STAGED="${TMP_DIR}/staged"
( umask 077
  if [ "$EFFECTIVE_MODE" = "json-key" ]; then
    KEY_EXISTED=$(jq -r --arg k "$SECRET_KEY" 'has($k)' < "$CURRENT_FILE")
    [ "$KEY_EXISTED" = "true" ] || warn "secret '${SECRET_NAME}' has no '${SECRET_KEY}' key yet; it will be added"
    # --arg passes the value as data: no quoting or escaping can corrupt it.
    jq --arg k "$SECRET_KEY" --arg v "$NEW_VALUE" '.[$k] = $v' < "$CURRENT_FILE" > "$STAGED"
  else
    printf '%s' "$NEW_VALUE" > "$STAGED"
  fi
) || die "could not stage the new secret value"
chmod 600 "$STAGED"
[ -s "$STAGED" ] || die "the staged secret value is empty; refusing to write it"

if [ "$EFFECTIVE_MODE" = "json-key" ]; then
  PRESERVED="$(jq -r 'keys | join(", ")' < "$STAGED")"
  info "staged JSON object with keys: ${PRESERVED}"
  # Prove the staged file carries the new value, without printing it.
  printf '%s' "$NEW_VALUE" | jq -Rs --slurpfile new "$STAGED" --arg k "$SECRET_KEY" \
    -e '($new[0][$k]) == .' >/dev/null 2>&1 \
    || die "the staged JSON does not contain the new value under '${SECRET_KEY}'"
else
  PRESERVED=""
  info "staged a plaintext replacement ($(wc -c < "$STAGED" | tr -d ' ') bytes)"
fi

# ------------------------------------------------------------------------------
# Write. The client request token makes a retried call idempotent: if the first
# attempt actually succeeded and only the response was lost, the retry returns
# the same version instead of creating a second one.
# ------------------------------------------------------------------------------
REQUEST_TOKEN="$(python3 -c 'import uuid; print(uuid.uuid4())')" \
  || die "could not generate a client request token"

if ! NEW_VERSION="$(aws secretsmanager put-secret-value \
      --secret-id "$SECRET_ID" \
      --region "$REGION" \
      --secret-string "file://${STAGED}" \
      --client-request-token "$REQUEST_TOKEN" \
      --query VersionId --output text 2>&1)"; then
  die "PutSecretValue FAILED on '${SECRET_NAME}': ${NEW_VERSION//$'\n'/ }. The secret still holds its previous value."
fi
info "wrote version ${NEW_VERSION}"

# ------------------------------------------------------------------------------
# Verify. Reporting success on the strength of an API 200 alone would miss a
# secret whose AWSCURRENT label did not move, and the whole point of a rotation is
# that the new value is the one consumers get.
# ------------------------------------------------------------------------------
VERIFY_FILE="${TMP_DIR}/verify"
if ! aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
      --version-stage AWSCURRENT --query SecretString --output text \
      > "$VERIFY_FILE" 2>"${TMP_DIR}/verify.err"; then
  die "the secret was written (version ${NEW_VERSION}) but reading it back FAILED, so the rotation is unverified: $(tr '\n' ' ' < "${TMP_DIR}/verify.err" | cut -c1-200)"
fi
chmod 600 "$VERIFY_FILE"
printf '%s' "$(cat "$VERIFY_FILE")" > "${VERIFY_FILE}.raw" && mv "${VERIFY_FILE}.raw" "$VERIFY_FILE"

if [ "$EFFECTIVE_MODE" = "json-key" ]; then
  printf '%s' "$NEW_VALUE" | jq -Rs --slurpfile cur "$VERIFY_FILE" --arg k "$SECRET_KEY" \
    -e '($cur[0][$k]) == .' >/dev/null 2>&1 \
    || die "AWSCURRENT on '${SECRET_NAME}' does not carry the new value under '${SECRET_KEY}' after version ${NEW_VERSION}"
else
  printf '%s' "$NEW_VALUE" | cmp -s - "$VERIFY_FILE" \
    || die "AWSCURRENT on '${SECRET_NAME}' does not match the value written in version ${NEW_VERSION}"
fi
info "verified AWSCURRENT carries the new value"

unset NEW_VALUE

# The value itself is never emitted: consumers read it from Secrets Manager, and
# this output lands in the broker log.
emit secret_arn "${SECRET_FULL_ARN:-$SECRET_ID}"
emit secret_name "$SECRET_NAME"
emit region "$REGION"
emit mode "$EFFECTIVE_MODE"
emit secret_key "$([ "$EFFECTIVE_MODE" = "json-key" ] && printf '%s' "$SECRET_KEY" || printf 'n/a')"
emit preserved_keys "${PRESERVED:-n/a}"
emit new_version "$NEW_VERSION"
emit rotated true
emit verified true
