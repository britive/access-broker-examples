#!/bin/sh
set -eu

TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)
NOW_EPOCH=$(date +%s)
EXPIRES_AT=$((NOW_EPOCH + EXPIRATION))
cat <<EOF | /opt/britive-broker/scripts/bridge.sh checkout-create --stdin >/dev/null
{
  "transaction_id": "${TRANSACTION_ID}",
  "protocol": "admin",
  "username": "${USERNAME}",
  "expires_at": ${EXPIRES_AT},
  "token": "${TOKEN}"
}
EOF
URL="${BRIDGE_URL}/admin#token=${TOKEN}"
printf '{"token": "%s", "url": "%s"}\n' "${TOKEN}" "${URL}"
