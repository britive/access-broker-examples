#!/bin/sh
# Checkout: register a role=admin checkout so the logged-in user gains admin-UI
# access (the review/admin surface at /user-sessions) for its lifetime. No token —
# the bridge authorizes from the session + this active admin checkout.
set -eu

NOW_EPOCH=$(date +%s)
EXPIRES_AT=$((NOW_EPOCH + EXPIRATION))
cat <<EOF | /opt/britive-broker/scripts/bridge.sh checkout-create --stdin >/dev/null
{
  "transaction_id": "${TRANSACTION_ID}",
  "role": "${ROLE}",
  "username": "${USERNAME}",
  "expires_at": ${EXPIRES_AT}
}
EOF
printf '{"browser_session": "https://%s/user-sessions"}\n' "${BRIDGE_URL}"
