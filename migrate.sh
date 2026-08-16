#!/usr/bin/env bash
#
# migrate.sh
# ----------------------------------------------------------------------------
# End-to-end migration for a single site: RunCloud backup → Ploi restore.
# Wraps runcloud-wp-backup.sh and ploi-migrate.sh with status tracking and
# a single point of control.
#
# Usage:
#   ./migrate.sh user server-ip [domain]
#
# Examples:
#   ./migrate.sh runcloud_user 198.51.100.10 example.com
#   RC_USER=... RC_IP=... DOMAIN=... ./migrate.sh
#
# The script:
#   1. backs up the RunCloud site
#   2. finds the downloaded zip
#   3. runs ploi-migrate.sh on that zip
#   4. updates the per-site status file
#
# Env overrides: all runcloud-wp-backup.sh and ploi-migrate.sh variables.
# ----------------------------------------------------------------------------

set -euo pipefail

# quick help before any work
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


BACKUP="$PROJECT_ROOT/runcloud-wp-backup.sh"
RESTORE="$PROJECT_ROOT/ploi-migrate.sh"
[ -x "$BACKUP" ] || die "backup script not found: $BACKUP"
[ -x "$RESTORE" ] || die "restore script not found: $RESTORE"

# arguments or env
RC_USER="${RC_USER:-${1:-}}"
RC_IP="${RC_IP:-${2:-}}"
DOMAIN="${DOMAIN:-${3:-}}"

[ -n "$RC_USER" ] || die "usage: $0 <ssh-user> <server-ip> [domain]"
[ -n "$RC_IP" ] || die "server IP is required"

SITE_KEY="${RC_USER}@${RC_IP}/${DOMAIN:-auto}"

step "End-to-end migration: $SITE_KEY"

# ── 1) backup ───────────────────────────────────────────────────────────────
update_status "$SITE_KEY" "backed_up" "running" ""
child_env=( RC_USER="$RC_USER" RC_IP="$RC_IP" BATCH=1 )
[ -n "$DOMAIN" ] && child_env+=( DOMAIN="$DOMAIN" )

step "Phase 1/2 — RunCloud backup"
out=$( env "${child_env[@]}" bash "$BACKUP" </dev/null 2>&1 ) || {
  update_status "$SITE_KEY" "backed_up" "fail" "exit=$?"
  printf '%s\n' "$out"
  die "RunCloud backup failed"
}
printf '%s\n' "$out"
zip_line=$(printf '%s\n' "$out" | grep -E 'Backup complete:' | tail -1)
zip_path="${zip_line#*Backup complete: }"
zip_path="$(strip_ansi "$zip_path")"
[ -f "$zip_path" ] || die "backup script succeeded but zip path not found: $zip_path"
log "Backup produced: $zip_path"
update_status "$SITE_KEY" "backed_up" "ok" "zip=$zip_path"

# ── 2) Ploi restore ─────────────────────────────────────────────────────────
step "Phase 2/2 — Ploi restore"
update_status "$SITE_KEY" "restored" "running" ""
if env DOMAIN="$DOMAIN" MIGRATION_KEY="$SITE_KEY" BATCH=1 bash "$RESTORE" "$zip_path" </dev/null 2>&1; then
  update_status "$SITE_KEY" "restored" "ok" ""
  log "Migration complete for $SITE_KEY"
else
  update_status "$SITE_KEY" "restored" "fail" "ploi-migrate exit=$?"
  die "Ploi restore failed for $SITE_KEY"
fi
