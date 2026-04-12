#!/bin/sh
# Checkin: terminate the Bridge k8sexec session and delete the RBAC binding.
# Bridge session is terminated FIRST so the WebSocket exec connection closes
# before the RBAC binding is removed.
#
# Required env vars: BRITIVE_USER_EMAIL, TRX, KUBE_NAMESPACE
# Optional: KUBE_CONTEXT, BROKER_API

set -eu

# --- Variables ---
USER_EMAIL="${BRITIVE_USER_EMAIL:-}"
TRANSACTION_ID="${TRX:-}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/bridge.sh}"

# --- Validation ---
fail() { echo "error: $1" >&2; exit 1; }

for var in BRITIVE_USER_EMAIL TRX KUBE_NAMESPACE; do
    eval "val=\${$var:-}"
    [ -n "$val" ] || fail "required env var missing: $var"
done

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

# --- Derive username (must match checkout) ---
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

# --- Terminate Bridge session first ---
"${BROKER_API}" checkout-delete "${TRANSACTION_ID}"
echo "[checkin] Bridge session terminated" >&2

# --- Delete RoleBinding ---
if kubectl get rolebinding "$BINDING_NAME" --namespace="$KUBE_NAMESPACE" $KUBE_FLAGS >/dev/null 2>&1; then
    kubectl delete rolebinding "$BINDING_NAME" --namespace="$KUBE_NAMESPACE" $KUBE_FLAGS
    echo "[checkin] RoleBinding ${BINDING_NAME} deleted" >&2
else
    echo "[checkin] RoleBinding ${BINDING_NAME} already absent" >&2
fi
