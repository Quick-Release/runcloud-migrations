#!/usr/bin/env bash
#
# ploi-wp-backup.sh
# ----------------------------------------------------------------------------
# Connects to a source Ploi server over SSH (as a privileged admin such as
# ploi/root), backs up one WordPress site, and downloads it to ./downloads
# as <domain>_<timestamp>.zip — ready to import on another Ploi server.
#
# The privileged admin is used because the source site's isolated system
# user may be chrooted (SFTP-only) and cannot run shell commands. The admin
# reads wp-config.php directly for DB credentials, then runs mysqldump.
#
# Usage:
#   ./ploi-wp-backup.sh <system-user> <domain>
#   PLOI_SOURCE_SYSTEM_USER=foo PLOI_SOURCE_DOMAIN=bar.com BATCH=1 ./ploi-wp-backup.sh
#
# Env overrides (see .env.example):
#   PLOI_SOURCE_SSH_HOST, PLOI_SOURCE_SSH_PORT, PLOI_SOURCE_SSH_USER,
#   PLOI_SOURCE_SSH_KEY, PLOI_SOURCE_WEB_DIRECTORY, PLOI_SOURCE_SITE_ROOT,
#   PLOI_SOURCE_SERVER_ID, PLOI_API_TOKEN, PLOI_API_URL,
#   DOMAIN, RC_CLEANUP_DB_DUMP, RC_CLEANUP_REMOTE_ZIP, RC_VERIFY_ZIP,
#   RC_MIN_FREE_BYTES.
# ----------------------------------------------------------------------------

set -euo pipefail

# quick help before any prompts
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

for bin in ssh scp zip unzip; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required local tool: $bin"
done

# ── source Ploi config ──────────────────────────────────────────────────────
PLOI_SOURCE_SERVER_ID="${PLOI_SOURCE_SERVER_ID:-}"
PLOI_SOURCE_SSH_HOST="${PLOI_SOURCE_SSH_HOST:-}"
PLOI_SOURCE_SSH_PORT="${PLOI_SOURCE_SSH_PORT:-22}"
PLOI_SOURCE_SSH_USER="${PLOI_SOURCE_SSH_USER:-ploi}"
PLOI_SOURCE_SSH_KEY="${PLOI_SOURCE_SSH_KEY:-$HOME/.ssh/id_ed25519}"
PLOI_SOURCE_WEB_DIRECTORY="${PLOI_SOURCE_WEB_DIRECTORY:-/public}"
PLOI_SOURCE_SITE_ROOT="${PLOI_SOURCE_SITE_ROOT:-}"

[ -f "$PLOI_SOURCE_SSH_KEY" ] || die "source Ploi SSH key not found: $PLOI_SOURCE_SSH_KEY"
[ -n "$PLOI_SOURCE_SSH_HOST" ] || die "PLOI_SOURCE_SSH_HOST is not set"

# ── gather target site details ──────────────────────────────────────────────
SYSTEM_USER="${PLOI_SOURCE_SYSTEM_USER:-${1:-}}"
DOMAIN="${DOMAIN:-${PLOI_SOURCE_DOMAIN:-${2:-}}}"

[ -n "$SYSTEM_USER" ] || die "usage: $0 <system-user> <domain>  (or set PLOI_SOURCE_SYSTEM_USER / PLOI_SOURCE_DOMAIN)"
[ -n "$DOMAIN" ] || die "domain is required"
DOMAIN="$(safe_domain "$DOMAIN")"
[ -n "$DOMAIN" ] || die "domain became empty after sanitization"

SITE_KEY="${MIGRATION_KEY:-ploi-source:${SYSTEM_USER}@${PLOI_SOURCE_SSH_HOST}/${DOMAIN}}"

# ── discover site root via Ploi API when possible ───────────────────────────
if [ -z "$PLOI_SOURCE_SITE_ROOT" ] && [ -n "$PLOI_API_TOKEN" ]; then
  ploi_ensure_source_server_id >/dev/null 2>&1 || true
  if [ -n "${PLOI_SOURCE_SERVER_ID:-}" ]; then
    step "Looking up site root via Ploi API …"
    site_json=$(ploi_source_curl GET "/servers/${PLOI_SOURCE_SERVER_ID}/sites" 2>/dev/null) || true
    if [ -n "${site_json:-}" ]; then
      found_root=$(printf '%s' "$site_json" | jq -r --arg d "$DOMAIN" '.data[] | select(.domain == $d) | .root_directory // empty' 2>/dev/null) || true
      [ -n "$found_root" ] && PLOI_SOURCE_SITE_ROOT="$found_root"
    fi
  fi
fi

# default Ploi layout if still unknown
if [ -z "$PLOI_SOURCE_SITE_ROOT" ]; then
  PLOI_SOURCE_SITE_ROOT="/home/${SYSTEM_USER}/${DOMAIN}"
fi
WEB_ROOT="${PLOI_SOURCE_SITE_ROOT%/}${PLOI_SOURCE_WEB_DIRECTORY}"

# ── test connection as privileged source admin ──────────────────────────────
step "Connecting to source Ploi server $(ploi_source_ssh_host):$PLOI_SOURCE_SSH_PORT …"
# shellcheck disable=SC2016
conn=$(ploi_source_remote 'printf "ok %s@%s" "$(whoami)" "$(hostname)"' 2>&1) || \
  die "SSH connection failed: $conn"
case "$conn" in
  ok\ *) log "Connected: ${conn#ok }" ;;
  *)     die "SSH connection failed: $conn" ;;
esac

# ── locate wp-config.php ────────────────────────────────────────────────────
step "Locating WordPress files for $DOMAIN …"
# shellcheck disable=SC2016
wp_config=$(ploi_source_remote '
  root="'"$PLOI_SOURCE_SITE_ROOT"'"
  web="'"$WEB_ROOT"'"
  for d in "$web" "$root" "$root/public_html" "$root/public" "$root/web" "$root/httpdocs"; do
    [ -f "$d/wp-config.php" ] && { printf "%s\n" "$d/wp-config.php"; exit 0; }
  done
  find "$root" -maxdepth 3 -name wp-config.php -type f 2>/dev/null | head -1
')
[ -n "$wp_config" ] || die "no wp-config.php found under $PLOI_SOURCE_SITE_ROOT"
WP_PATH="$(dirname "$wp_config")"
log "WordPress path: $WP_PATH"

# ── read DB credentials from wp-config.php ────────────────────────────────────
step "Reading database credentials from wp-config.php …"
creds_tmp="$(mktemp)"
trap 'rm -f "$creds_tmp"' EXIT
# shellcheck disable=SC2016
ploi_source_remote '
  f="'"$wp_config"'"
  get() {
    grep -oE "define\s*\(\s*[\\\x27\"]?$1[\\\x27\"]?\s*,\s*[\\\x27\"]?[^\\\x27\"]+[\\\x27\"]?" "$f" 2>/dev/null | head -1 |
      sed -E "s/.*,\s*[\\\x27\"]?([^\\\x27\"]+)[\\\x27\"]?$/\1/"
  }
  printf "%s\n%s\n%s\n%s\n" "$(get DB_NAME)" "$(get DB_USER)" "$(get DB_PASSWORD)" "$(get DB_HOST)"
' > "$creds_tmp"

DB_NAME="$(sed -n '1p' "$creds_tmp")"
DB_USER="$(sed -n '2p' "$creds_tmp")"
DB_PASS="$(sed -n '3p' "$creds_tmp")"
DB_HOST="$(sed -n '4p' "$creds_tmp")"
DB_HOST="${DB_HOST:-127.0.0.1}"

[ -n "$DB_NAME" ] || die "could not read DB_NAME from $wp_config"
[ -n "$DB_USER" ] || die "could not read DB_USER from $wp_config"
[ -n "$DB_PASS" ] || die "could not read DB_PASSWORD from $wp_config"
log "Database: $DB_NAME @ ${DB_HOST:-127.0.0.1}"

# ── plan & space checks ─────────────────────────────────────────────────────
update_status "$SITE_KEY" "backed_up" "running" ""
RC_MIN_FREE_BYTES="${RC_MIN_FREE_BYTES:-2147483648}"
local_free=$(df -P "$DOWNLOADS_DIR" | awk 'NR==2 {print $4*1024}')
[ "$local_free" -ge "$RC_MIN_FREE_BYTES" ] || die "not enough local disk space: $(human_bytes "$local_free") available"

stamp=$(date +%Y%m%d-%H%M%S)
FILE="${DOMAIN}_${stamp}.zip"
DUMP_NAME="db_export_${stamp}.sql"
# shellcheck disable=SC2016
REMOTE_ZIP_DIR=$(ploi_source_remote 'mktemp -d "${HOME:-/tmp}/.ploisrc.XXXXXX"' || true)
[ -n "$REMOTE_ZIP_DIR" ] || die "could not create remote temp dir"
REMOTE_ZIP="$REMOTE_ZIP_DIR/$FILE"

cat >&2 <<PLAN

${C_B}Backup plan${C_0}
  server     : $(ploi_source_ssh_host):$PLOI_SOURCE_SSH_PORT
  system user: $SYSTEM_USER
  site root  : $PLOI_SOURCE_SITE_ROOT
  wp path    : $WP_PATH
  domain     : $DOMAIN
  db dump    : $DUMP_NAME
  archive    : $REMOTE_ZIP
  save to    : $DOWNLOADS_DIR/$FILE
PLAN
ask_yn "Proceed with backup?" y || die "aborted"

# ── 1) export database ──────────────────────────────────────────────────────
step "Exporting database …"
# shellcheck disable=SC2086
ploi_source_remote "
  mysqldump -h $(shquote \"${DB_HOST:-127.0.0.1}\") -u $(shquote \"$DB_USER\") -p$(shquote \"$DB_PASS\") --single-transaction --add-drop-table $(shquote \"$DB_NAME\") > $(shquote \"$WP_PATH/$DUMP_NAME\")
" || die "mysqldump failed (check that the admin user can reach MySQL with the site credentials)"
log "DB exported → $WP_PATH/$DUMP_NAME"

# ── 2) archive ──────────────────────────────────────────────────────────────
RC_CLEANUP_REMOTE_ZIP="${RC_CLEANUP_REMOTE_ZIP:-yes}"
step "Archiving site files on source server …"
ploi_source_remote "
  cd $(shquote "$WP_PATH") &&
  zip -r -q $(shquote "$REMOTE_ZIP") . -x '*.git/*' -x 'node_modules/*' -x 'wp-content/cache/*' -x 'wp-content/uploads/cache/*'
" || { ploi_source_remote "rm -rf $(shquote "$REMOTE_ZIP_DIR")" 2>/dev/null || true; die "remote zip failed"; }

step "Downloading $FILE …"
if scp -P "$PLOI_SOURCE_SSH_PORT" -i "$PLOI_SOURCE_SSH_KEY" \
     -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
     "$(ploi_source_ssh_host):$REMOTE_ZIP" "$DOWNLOADS_DIR/$FILE"; then
  log "Downloaded → $DOWNLOADS_DIR/$FILE"
else
  ploi_source_remote "rm -rf $(shquote "$REMOTE_ZIP_DIR")" 2>/dev/null || true
  die "scp download failed"
fi

if [ "$RC_CLEANUP_REMOTE_ZIP" = "yes" ]; then
  ploi_source_remote "rm -rf $(shquote "$REMOTE_ZIP_DIR")" || warn "could not remove remote temp dir"
fi

# ── 3) verify archive ───────────────────────────────────────────────────────
RC_VERIFY_ZIP="${RC_VERIFY_ZIP:-yes}"
if [ "$RC_VERIFY_ZIP" = "yes" ]; then
  step "Verifying downloaded archive …"
  unzip -t "$DOWNLOADS_DIR/$FILE" >/dev/null 2>&1 || die "downloaded archive is corrupt"
  log "Archive verified"
fi

# ── 4) cleanup DB dump on source ────────────────────────────────────────────
RC_CLEANUP_DB_DUMP="${RC_CLEANUP_DB_DUMP:-yes}"
if [ "$RC_CLEANUP_DB_DUMP" = "yes" ]; then
  step "Cleaning up DB dump on source server …"
  ploi_source_remote "rm -f $(shquote "$WP_PATH/$DUMP_NAME")" || warn "could not remove DB dump"
fi

# ── done ────────────────────────────────────────────────────────────────────
echo >&2
update_status "$SITE_KEY" "backed_up" "ok" "zip=$DOWNLOADS_DIR/$FILE"
log "Backup complete: $DOWNLOADS_DIR/$FILE"
