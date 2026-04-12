#!/bin/sh
# Checkout: create a short-lived K8s RBAC binding, register a Bridge k8sexec
# session, and return a browser URL for container exec access.
#
# Required env vars: BRITIVE_USER_EMAIL, TRX, BRIDGE_URL, EXPIRATION,
#   KUBE_API_SERVER, KUBE_NAMESPACE, KUBE_POD
# Optional: KUBE_CONTAINER, KUBE_COMMAND(["/bin/sh"]), KUBE_TTY(true),
#   KUBE_ROLE(britive-exec), KUBE_CONTEXT, KUBE_TOKEN_CMD,
#   EKS_CLUSTER, AWS_REGION, BROKER_API

set -eu

# --- Variables ---
USER_EMAIL="${BRITIVE_USER_EMAIL:-}"
TRANSACTION_ID="${TRX:-}"
BRIDGE_URL="${BRIDGE_URL:-}"
EXPIRATION="${EXPIRATION:-}"
KUBE_API_SERVER="${KUBE_API_SERVER:-}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-}"
KUBE_POD="${KUBE_POD:-}"
KUBE_CONTAINER="${KUBE_CONTAINER:-}"
KUBE_COMMAND="${KUBE_COMMAND:-[\"/bin/sh\"]}"
KUBE_TTY="${KUBE_TTY:-true}"
KUBE_ROLE="${KUBE_ROLE:-britive-exec}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
KUBE_TOKEN_CMD="${KUBE_TOKEN_CMD:-}"
EKS_CLUSTER="${EKS_CLUSTER:-}"
AWS_REGION="${AWS_REGION:-}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/bridge.sh}"

# --- Validation ---
fail() { echo "error: $1" >&2; exit 1; }

for var in BRITIVE_USER_EMAIL TRX BRIDGE_URL EXPIRATION KUBE_API_SERVER KUBE_NAMESPACE KUBE_POD; do
    eval "val=\${$var:-}"
    [ -n "$val" ] || fail "required env var missing: $var"
done

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

# --- Derive username for RBAC binding ---
USERNAME="$(python3 -c "
import re, sys
name = re.sub(r'[^a-z0-9]', '', sys.argv[1].split('@')[0].lower())
if not name:
    sys.exit('error: cannot derive username from: ' + sys.argv[1])
print(name[:63])
" "$USER_EMAIL")"

BINDING_NAME="britive-${USERNAME}-${TRANSACTION_ID}"

# --- Build kubectl context flags ---
KUBE_FLAGS=""
if [ -n "$KUBE_CONTEXT" ]; then
    KUBE_FLAGS="--context ${KUBE_CONTEXT}"
fi

# --- Create RoleBinding for exec access ---
echo "[checkout] creating RoleBinding ${BINDING_NAME} in ${KUBE_NAMESPACE}" >&2

kubectl create rolebinding "$BINDING_NAME" \
    --role="$KUBE_ROLE" \
    --user="$USER_EMAIL" \
    --namespace="$KUBE_NAMESPACE" \
    $KUBE_FLAGS

echo "[checkout] RBAC binding created" >&2

# --- Obtain bearer token for Bridge to use ---
# Priority: KUBE_TOKEN_CMD > EKS_CLUSTER (aws eks get-token) > service account token file
if [ -n "$KUBE_TOKEN_CMD" ]; then
    KUBE_BEARER_TOKEN="$(eval "$KUBE_TOKEN_CMD")"
elif [ -n "$EKS_CLUSTER" ]; then
    command -v aws >/dev/null 2>&1 || fail "aws CLI not found (required for EKS token)"
    REGION_FLAG=""
    [ -n "$AWS_REGION" ] && REGION_FLAG="--region ${AWS_REGION}"
    KUBE_BEARER_TOKEN="$(aws eks get-token --cluster-name "$EKS_CLUSTER" $REGION_FLAG --output text --query 'status.token')"
else
    # Fall back to mounted service account token
    SA_TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"
    [ -f "$SA_TOKEN_PATH" ] || fail "no token source: set KUBE_TOKEN_CMD, EKS_CLUSTER, or mount a service account token"
    KUBE_BEARER_TOKEN="$(cat "$SA_TOKEN_PATH")"
fi

echo "[checkout] bearer token obtained" >&2

# --- Build Bridge payload ---
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"' EXIT INT TERM
umask 077

TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
EXPIRES_AT="$(($(date +%s) + EXPIRATION))"

# JSON-encode the bearer token safely
BEARER_JSON="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$KUBE_BEARER_TOKEN")"

# Build target_host as pod reference for Bridge
TARGET_HOST="${KUBE_POD}"

cat > "$PAYLOAD_FILE" <<EOF
{
  "transaction_id":    "${TRANSACTION_ID}",
  "protocol":          "k8sexec",
  "username":          "${USER_EMAIL}",
  "target_host":       "${KUBE_API_SERVER}",
  "target_port":       443,
  "target_username":   "${TARGET_HOST}",
  "kube_api_server":   "${KUBE_API_SERVER}",
  "kube_namespace":    "${KUBE_NAMESPACE}",
  "kube_container":    "${KUBE_CONTAINER}",
  "kube_command":      ${KUBE_COMMAND},
  "kube_tty":          ${KUBE_TTY},
  "kube_bearer_token": ${BEARER_JSON},
  "expires_at":        ${EXPIRES_AT},
  "token":             "${TOKEN}"
}
EOF

"${BROKER_API}" checkout-create --file "$PAYLOAD_FILE" >/dev/null
echo "[checkout] Bridge session registered" >&2

# --- Output ---
URL="${BRIDGE_URL}/k8s/#token=${TOKEN}&transaction_id=${TRANSACTION_ID}"
printf '{"token": "%s", "url": "%s"}\n' "${TOKEN}" "${URL}"
