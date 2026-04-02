#!/usr/bin/env bash
# ============================================================
# Lab Teardown — HashiCorp Vault
# ============================================================
# Stops and removes the Docker Vault container and volumes,
# and removes the local .env file.
#
# Any data stored in the dev-mode container is ephemeral and
# lost when the container stops — no remote state to clean.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN: $*" >&2; }

# ── Load .env (optional — just for reference) ────────────────
[[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}"; set +a; } \
    || warn ".env not found — will still try to stop the container."

# ── Detect Compose command ────────────────────────────────────
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    warn "Docker Compose not found — attempting direct docker stop."
    docker stop  britive-lab-vault 2>/dev/null || warn "Container not running."
    docker rm -f britive-lab-vault 2>/dev/null || warn "Container not found."
    rm -f "${ENV_FILE}"
    log "Teardown complete."
    exit 0
fi

# ── Stop and remove container + volumes ──────────────────────
log "Stopping Vault container..."
${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" down --volumes 2>/dev/null \
    && log "  Container stopped and removed." \
    || warn "  Container may already be stopped."

# ── Remove .env ───────────────────────────────────────────────
rm -f "${ENV_FILE}"
log ".env removed."

log "Teardown complete."
