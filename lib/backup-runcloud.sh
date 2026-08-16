#!/usr/bin/env bash
#
# lib/backup-runcloud.sh
# ----------------------------------------------------------------------------
# Backs up one RunCloud application to a .zip file and uploads it to Cloudflare
# R2. The app is found by SSH-ing into the RunCloud server as RC_USER and
# searching common RunCloud webapp directories.
#
# If the app is a WordPress site, the database is also exported using the
# credentials read from wp-config.php.
#
# Usage:
#   RC_IP=203.0.113.10 RC_USER=runcloud RC_APP_NAME=myapp \
#     R2_BUCKET=backups R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... \
#     R2_SECRET_ACCESS_KEY=... ./lib/backup-runcloud.sh
#
# Optional env:
#   SSH_KEY, SSH_PORT, R2_PUBLIC_DOMAIN, R2_URL_TTL_SECONDS,
#   BACKUPS_DIR (default ./backups), RC_BACKUP_TEMP_DIR
# ----------------------------------------------------------------------------

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


RC_IP="${RC_IP:-}"
RC_USER="${RC_USER:-}"
RC_APP_NAME="${RC_APP_NAME:-}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="${SSH_PORT:-22}"
BACKUPS_DIR="${BACKUPS_DIR:-$PROJECT_ROOT/backups}"

[ -n "$RC_IP" ] || die "RC_IP is not set"
[ -n "$RC_USER" ] || die "RC_USER is not set"
[ -n "$RC_APP_NAME" ] || die "RC_APP_NAME is not set"
[ -f "$SSH_KEY" ] || die "SSH key not found: $SSH_KEY"

mkdir -p "$BACKUPS_DIR"

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30
          -o ConnectTimeout=15
          -o BatchMode=yes)

SSH_HOST="${RC_USER}@${RC_IP}"

# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$1"; }

step "Connecting to RunCloud server $SSH_HOST ..."
remote 'printf ok\n' >/dev/null || die "SSH connection failed to $SSH_HOST"

step "Locating app directory for '$RC_APP_NAME}' ..."
APP_DIR=$(
  # shellcheck disable=SC2016
  remote "
    for base in /home/${RC_USER}/webapps /home/${RC_USER}/apps /var/www /srv; do
      [ -d \"\${base}/${RC_APP_NAME}\" ] && { printf '%s\n' \"\${base}/${RC_APP_NAME}\"; exit 0; }
    done
    # generic find as a last resort
    find /home -maxdepth 3 -type d -name '${RC_APP_NAME}' 2>/dev/null | head -n1
  "
) || true

[ -n "$APP_DIR" ] || die "Could not find app directory for '$RC_APP_NAME' on $SSH_HOST"
log "Found app directory: $APP_DIR"

# Detect WordPress.
IS_WORDPRESS="no"
if remote "[ -f $(shquote "$APP_DIR/wp-config.php") ]"; then
  IS_WORDPRESS="yes"
  log "WordPress detected in $APP_DIR"
else
  warn "No wp-config.php found - backing up files only"
fi

stamp=$(date +%Y%m%d-%H%M%S)
SAFE_APP=$(printf '%s' "$RC_APP_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g')
ZIP_NAME="${SAFE_APP}_${stamp}.zip"
LOCAL_ZIP="$BACKUPS_DIR/$ZIP_NAME"
DUMP_NAME="db_export_${stamp}.sql"
REMOTE_TEMP=$(
  # shellcheck disable=SC2016
  remote 'mktemp -d "${HOME:-/tmp}/.rcbackup.XXXXXX"' || true
)
[ -n "$REMOTE_TEMP" ] || die "Could not create remote temp directory"

if [ "$IS_WORDPRESS" = "yes" ]; then
  step "Exporting WordPress database ..."
  creds_tmp=$(mktemp)
  trap 'rm -f "$creds_tmp"' EXIT

  # shellcheck disable=SC2016
  remote '
    f="'"$APP_DIR/wp-config.php"'"
    get() {
      grep -oE "define\s*\(\s*[\\\x27\"]?$1[\\\x27\"]?\s*,\s*[\\\x27\"]?[^\\\x27\"]+[\\\x27\"]?" "$f" 2>/dev/null | head -1 |
        sed -E "s/.*,\s*[\\\x27\"]?([^\\\x27\"]+)[\\\x27\"]?$/\1/"
    }
    printf "%s\n%s\n%s\n%s\n" "$(get DB_NAME)" "$(get DB_USER)" "$(get DB_PASSWORD)" "$(get DB_HOST)"
  ' > "$creds_tmp"

  DB_NAME="$(sed -n '1p' "$creds_tmp")"
  DB_USER="$(sed -n '2p' "$creds_tmp")"
  DB_PASSWORD="$(sed -n '3p' "$creds_tmp")"
  DB_HOST="$(sed -n '4p' "$creds_tmp")"
  DB_HOST="${DB_HOST:-localhost}"

  if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
    MYSQL_PRESERVE="$REMOTE_TEMP/${DUMP_NAME}"
    # shellcheck disable=SC2016
    remote "
      cd $(shquote "$APP_DIR")
      if command -v mysqldump >/dev/null 2>&1; then
        mysqldump --single-transaction --quick \
          -h $(shquote "$DB_HOST") -u $(shquote "$DB_USER") -p$(shquote "$DB_PASSWORD") \
          $(shquote "$DB_NAME") > $(shquote "$MYSQL_PRESERVE")
      elif command -v wp >/dev/null 2>&1; then
        wp db export $(shquote "$MYSQL_PRESERVE") --allow-root 2>/dev/null || \
          wp db export $(shquote "$MYSQL_PRESERVE") 2>/dev/null
      else
        exit 1
      fi
    " || die "Database export failed (tried mysqldump and wp-cli)"
    log "Database exported to $MYSQL_PRESERVE"
  else
    warn "Could not parse DB credentials from wp-config.php; database will not be included"
    MYSQL_PRESERVE=""
  fi
else
  MYSQL_PRESERVE=""
fi

step "Creating remote zip archive ..."
# shellcheck disable=SC2016
remote "
  cd $(shquote "$APP_DIR") || exit 1
  if command -v zip >/dev/null 2>&1; then
    zip -r $(shquote "$REMOTE_TEMP/$ZIP_NAME") . -x '*.git*' -x '*.log' -x 'node_modules/*' -x 'vendor/*' >/dev/null
  else
    # fall back to tar + gzip if zip is missing, then rename to .zip for convenience
    tar -czf $(shquote "$REMOTE_TEMP/${ZIP_NAME%.zip}.tar.gz") .
    mv $(shquote "$REMOTE_TEMP/${ZIP_NAME%.zip}.tar.gz") $(shquote "$REMOTE_TEMP/$ZIP_NAME")
  fi
  [ -n $(shquote "$MYSQL_PRESERVE") ] && zip -j $(shquote "$REMOTE_TEMP/$ZIP_NAME") $(shquote "$MYSQL_PRESERVE") >/dev/null
  ls -lh $(shquote "$REMOTE_TEMP/$ZIP_NAME") | awk '{print \$5}'
" || die "Remote zip creation failed"

REMOTE_SIZE=$(
  # shellcheck disable=SC2016,SC2086
  remote "ls -l $(shquote \"$REMOTE_TEMP/$ZIP_NAME\") | awk '{print \$5}'" || true
)
[ -n "$REMOTE_SIZE" ] || warn "Could not read remote zip size"

step "Downloading backup to $LOCAL_ZIP ..."
scp -P "$SSH_PORT" -i "$SSH_KEY" \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
  "$SSH_HOST:$REMOTE_TEMP/$ZIP_NAME" "$LOCAL_ZIP" || die "Download failed"

if [ -f "$LOCAL_ZIP" ]; then
  LOCAL_SIZE=$(stat -f%z "$LOCAL_ZIP" 2>/dev/null || stat -c%s "$LOCAL_ZIP" 2>/dev/null || true)
  [ -n "$LOCAL_SIZE" ] && [ -n "$REMOTE_SIZE" ] && [ "$LOCAL_SIZE" = "$REMOTE_SIZE" ] || \
    warn "Local zip size differs from remote; verify $LOCAL_ZIP"
fi

step "Uploading backup to R2 ..."
R2_OBJECT_KEY="runcloud/${SAFE_APP}/${ZIP_NAME}"
R2_URL=$("$PROJECT_ROOT/lib/r2-upload.sh" "$LOCAL_ZIP" "$R2_OBJECT_KEY") || die "R2 upload failed"

step "Cleaning up remote temp directory ..."
# shellcheck disable=SC2086
remote "rm -rf $(shquote \"$REMOTE_TEMP\")" || warn "could not remove remote temp dir"

EXPIRES_AT=$(date -u -d "@${R2_URL_TTL_SECONDS:-2592000} seconds" +%FT%TZ 2>/dev/null || date -u -v+30d +%FT%TZ)

log "Backup complete"

cat <<EOF
status=ok
app_name=$RC_APP_NAME
server_ip=$RC_IP
ssh_user=$RC_USER
app_dir=$APP_DIR
is_wordpress=$IS_WORDPRESS
db_included=$([ -n "$MYSQL_PRESERVE" ] && echo yes || echo no)
local_path=$LOCAL_ZIP
zip_name=$ZIP_NAME
zip_size_bytes=${LOCAL_SIZE:-${REMOTE_SIZE:-}}
r2_bucket=$R2_BUCKET
r2_key=$R2_OBJECT_KEY
r2_url=$R2_URL
expires_at=$EXPIRES_AT
EOF
