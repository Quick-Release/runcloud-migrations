#!/usr/bin/env bash
#
# coolify-remove.sh
# ----------------------------------------------------------------------------
# Removes a Coolify service (WordPress site) from the source server after it
# has been migrated to Ploi.
#
# Usage:
#   SSH_HOST=root@203.0.113.30 COOLIFY_SERVICE_UUID=abc-123 ./coolify-remove.sh
#
# Env overrides:
#   SSH_HOST, SSH_PORT, SSH_KEY, COOLIFY_SERVICE_UUID, COOLIFY_REMOVE_DATA.
# ----------------------------------------------------------------------------

set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
COOLIFY_SERVICE_UUID="${COOLIFY_SERVICE_UUID:-${1:-}}"
COOLIFY_REMOVE_DATA="${COOLIFY_REMOVE_DATA:-yes}"

[ -n "$SSH_HOST" ] || die "SSH_HOST is not set"
[ -n "$COOLIFY_SERVICE_UUID" ] || die "COOLIFY_SERVICE_UUID is required"
[ -f "$SSH_KEY" ] || die "SSH key not found: $SSH_KEY"

SERVICE_DIR="/data/coolify/services/${COOLIFY_SERVICE_UUID}"

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30
          -o ConnectTimeout=15)

# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$1"; }

step "Preparing to remove Coolify service $COOLIFY_SERVICE_UUID on $SSH_HOST"

# verify the directory exists
# shellcheck disable=SC2086
if ! remote "[ -d $(shquote \"$SERVICE_DIR\") ]" 2>/dev/null; then
  die "Coolify service directory not found: $SERVICE_DIR"
fi

# show compose services for transparency
# shellcheck disable=SC2086
services=$(remote "cd $(shquote \"$SERVICE_DIR\") && (docker compose ps --services 2>/dev/null || docker-compose ps --services 2>/dev/null)" 2>/dev/null || true)
[ -n "$services" ] && echo "Services in project:" && printf '%s\n' "$services"

cat >&2 <<WARN

${C_R}WARNING:${C_0} This will stop and remove the Coolify service
  ${COOLIFY_SERVICE_UUID}
from
  ${SSH_HOST}:${SERVICE_DIR}

This script is meant to be run manually **after** you have visually verified
that the migration to Ploi was successful and DNS has been switched. This
action is irreversible.
WARN
ask_yn "Really remove this Coolify service?" n || die "aborted"

step "Stopping and removing Coolify service …"
# shellcheck disable=SC2086
remote "
  cd $(shquote \"$SERVICE_DIR\") || exit 1
  if command -v docker compose >/dev/null 2>&1; then
    docker compose down 2>/dev/null || true
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose down 2>/dev/null || true
  fi
" || warn "docker compose down failed (containers may already be stopped)"

if [ "$COOLIFY_REMOVE_DATA" = "yes" ]; then
  step "Removing service directory and bind-mounted data …"
  # shellcheck disable=SC2086
  remote "rm -rf $(shquote \"$SERVICE_DIR\")" || die "could not remove $SERVICE_DIR"
  log "Removed $SERVICE_DIR"
else
  log "Service stopped. Data left in place because COOLIFY_REMOVE_DATA=no"
fi

echo >&2
log "Coolify service $COOLIFY_SERVICE_UUID removed"
