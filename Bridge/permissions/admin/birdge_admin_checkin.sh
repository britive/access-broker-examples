#!/bin/sh
set -eu

/opt/britive-broker/scripts/bridge.sh checkout-delete "${TRANSACTION_ID}"
