#!/usr/bin/env bash
#
# ploi-to-ploi.sh
# ----------------------------------------------------------------------------
# End-to-end migration for a single site: Ploi source -> Ploi target.
# Wraps ploi-wp-backup.sh and ploi-migrate.sh with status tracking and a
# single point of control.
#
# Usage:
#   ./ploi-to-ploi.sh <source-system-user> <domain>
#
# Examples:
#   ./ploi-to-ploi.sh example example.com
#   PLOI_SOURCE_SYSTEM_USER=example PLOI_SOURCE_DOMAIN=example.com ./ploi-to-ploi.sh
#
# Env overrides: all ploi-wp-backup.sh and ploi-migrate.sh variables.
# ----------------------------------------------------------------------------

set -euo pipefail

# quick help before any work
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


BACKUP="$PROJECT_ROOT/ploi-wp-backup.sh"
RESTORE="$PROJECT_ROOT/ploi-migrate.sh"
[ -x "$BACKUP" ] || die "backup script not found: $BACKUP"
[ -x "$RESTORE" ] || die "restore script not found: $RESTORE"

SYSTEM_USER="${PLOI_SOURCE_SYSTEM_USER:-${1:-}}"
DOMAIN="${DOMAIN:-${PLOI_SOURCE_DOMAIN:-${2:-}}}"

[ -n "$SYSTEM_USER" ] || die "usage: $0 <source-system-user> <domain>"
[ -n "$DOMAIN" ] || die "domain is required"

SITE_KEY="ploi-to-ploi:${SYSTEM_USER}@${PLOI_SOURCE_SSH_HOST:-?}/${DOMAIN}"

step "End-to-end migration: $SITE_KEY"

# -- 1) backup from source Ploi ------------------------------------------------
update_status "$SITE_KEY" "backed_up" "running" ""
child_env=( PLOI_SOURCE_SYSTEM_USER="$SYSTEM_USER" PLOI_SOURCE_DOMAIN="$DOMAIN" DOMAIN="$DOMAIN" BATCH=1 )

step "Phase 1/2 - Ploi source backup"
out=$( env "${child_env[@]}" bash "$BACKUP" </dev/null 2>&1 ) || {
  update_status "$SITE_KEY" "backed_up" "fail" "exit=$?"
  printf '%s\n' "$out"
  die "Ploi source backup failed"
}
printf '%s\n' "$out"
zip_line=$(printf '%s\n' "$out" | grep -E 'Backup complete:' | tail -1)
zip_path="${zip_line#*Backup complete: }"
zip_path="$(strip_ansi "$zip_path")"
[ -f "$zip_path" ] || die "backup script succeeded but zip path not found: $zip_path"
log "Backup produced: $zip_path"
update_status "$SITE_KEY" "backed_up" "ok" "zip=$zip_path"

# -- 2) restore to target Ploi -----------------------------------------------
step "Phase 2/2 - Ploi target restore"
update_status "$SITE_KEY" "restored" "running" ""
if env DOMAIN="$DOMAIN" MIGRATION_KEY="$SITE_KEY" BATCH=1 bash "$RESTORE" "$zip_path" </dev/null 2>&1; then
  update_status "$SITE_KEY" "restored" "ok" ""
  log "Migration complete for $SITE_KEY"
else
  update_status "$SITE_KEY" "restored" "fail" "ploi-migrate exit=$?"
  die "Ploi target restore failed for $SITE_KEY"
fi
