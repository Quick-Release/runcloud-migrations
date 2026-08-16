#!/usr/bin/env bash
#
# ssh-wp-backup.sh
# ----------------------------------------------------------------------------
# Generic SSH WordPress backup. Connects to any server where the site files are
# reachable over SSH (DigitalOcean droplets, Coolify host bind-mounts, VPSs),
# finds the WordPress install matching DOMAIN, exports the DB with wp-cli, zips
# the site, and downloads it to ./downloads.
#
# Usage:
#   SSH_HOST=root@198.51.100.10 DOMAIN=example.com ./ssh-wp-backup.sh
#
# Env overrides:
#   SSH_HOST, SSH_PORT, SSH_KEY, SSH_USER (only used if SSH_HOST has no @),
#   DOMAIN, RC_CLEANUP_DB_DUMP, RC_CLEANUP_REMOTE_ZIP, RC_VERIFY_ZIP,
#   RC_MIN_FREE_BYTES.
# ----------------------------------------------------------------------------

set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


for bin in ssh scp zip unzip; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required local tool: $bin"
done

# ── config ─────────────────────────────────────────────────────────────────
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_USER="${SSH_USER:-}"
DOMAIN="${DOMAIN:-}"

[ -n "$DOMAIN" ] || die "DOMAIN is not set"
[ -f "$SSH_KEY" ] || die "SSH key not found: $SSH_KEY"

# If SSH_HOST has no @, prepend SSH_USER
if [ -n "$SSH_USER" ] && [[ "$SSH_HOST" != *@* ]]; then
  SSH_HOST="${SSH_USER}@${SSH_HOST}"
fi
[ -n "$SSH_HOST" ] || die "SSH_HOST is not set"

SITE_KEY="${MIGRATION_KEY:-ssh:${SSH_HOST}/${DOMAIN}}"

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30
          -o ConnectTimeout=15)

# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$1"; }

# ── connection test ─────────────────────────────────────────────────────────
step "Connecting to $SSH_HOST:$SSH_PORT …"
# shellcheck disable=SC2016
conn=$(remote 'printf "ok %s@%s" "$(whoami)" "$(hostname)"' 2>&1) || \
  die "SSH connection failed: $conn"
case "$conn" in
  ok\ *) log "Connected: ${conn#ok }" ;;
  *)     die "SSH connection failed: $conn" ;;
esac

# ── find WordPress path matching DOMAIN ─────────────────────────────────────
step "Searching for WordPress install matching $DOMAIN …"
# shellcheck disable=SC2016
wp_cmd=$(remote '
  if command -v wp >/dev/null 2>&1; then
    printf wp\n
  elif command -v php >/dev/null 2>&1; then
    for c in /usr/local/bin/wp-cli.phar /usr/bin/wp-cli.phar /opt/wp-cli.phar "$HOME/wp-cli.phar"; do
      [ -f "$c" ] && { printf "php %s\n" "$c"; exit 0; }
    done
    cd "$HOME" || exit 1
    if command -v curl >/dev/null 2>&1; then
      curl -sS -o wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    else
      wget -q -O wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    fi && chmod +x wp-cli.phar && { printf "php $HOME/wp-cli.phar\n"; exit 0; }
    printf none\n
  else
    printf none\n
  fi
')
[ "$wp_cmd" != "none" ] && [ -n "$wp_cmd" ] || die "wp-cli (or php) not available on $SSH_HOST"
# Escape $ so remote variables are not expanded locally.
wp_cmd=$(printf '%s' "$wp_cmd" | sed 's/\$/\\$/g')

# shellcheck disable=SC2016
paths=$(remote '
  for root in "$HOME" /var/www /var/www/html /srv /webapps /usr/share/nginx/html /home /opt /data/coolify/services /var/web; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 7 \( -name wp-config.php -o -name wp-cli.yml \) -type f 2>/dev/null
  done | sort -u | while read -r f; do
    d=$(dirname "$f")
    { [ -f "$d/wp-settings.php" ] || [ -f "$d/wp-includes/version.php" ]; } && printf "%s\n" "$d"
  done | sort -u
')
[ -n "$paths" ] || die "no WordPress installs found on $SSH_HOST"

norm_domain() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#^www\.##; s#/.*##' | tr -c 'a-z0-9.-' '-' | tr -s '-' | sed 's/^-//;s/-$//'
}
target_norm=$(norm_domain "$DOMAIN")
target_www_norm=$(norm_domain "www.$DOMAIN")

WP_PATH=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  # shellcheck disable=SC2016
  siteurl=$(remote "cd $(shquote "$d") && $wp_cmd option get siteurl 2>/dev/null" || true)
  [ -n "$siteurl" ] || continue
  site_norm=$(norm_domain "$siteurl")
  if [ "$site_norm" = "$target_norm" ] || [ "$site_norm" = "$target_www_norm" ]; then
    WP_PATH="$d"
    break
  fi
done <<< "$paths"

[ -n "$WP_PATH" ] || die "no WordPress install matches $DOMAIN on $SSH_HOST"
log "WordPress path: $WP_PATH"

# ── space checks & plan ─────────────────────────────────────────────────────
update_status "$SITE_KEY" "backed_up" "running" ""
RC_MIN_FREE_BYTES="${RC_MIN_FREE_BYTES:-2147483648}"
local_free=$(df -P "$DOWNLOADS_DIR" | awk 'NR==2 {print $4*1024}')
[ "$local_free" -ge "$RC_MIN_FREE_BYTES" ] || die "not enough local disk space: $(human_bytes "$local_free") available"

stamp=$(date +%Y%m%d-%H%M%S)
FILE="${DOMAIN}_${stamp}.zip"
DUMP_NAME="db_export_${stamp}.sql"
REMOTE_ZIP_DIR=$(
  # shellcheck disable=SC2016
  remote 'mktemp -d "${HOME:-/tmp}/.sshsrc.XXXXXX"' || true
)
[ -n "$REMOTE_ZIP_DIR" ] || die "could not create remote temp dir"
REMOTE_ZIP="$REMOTE_ZIP_DIR/$FILE"

cat >&2 <<PLAN

${C_B}Backup plan${C_0}
  server   : $SSH_HOST:$SSH_PORT
  wp path  : $WP_PATH
  domain   : $DOMAIN
  db dump  : $DUMP_NAME
  archive  : $REMOTE_ZIP
  save to  : $DOWNLOADS_DIR/$FILE
PLAN
ask_yn "Proceed with backup?" y || die "aborted"

# ── 1) export database ──────────────────────────────────────────────────────
step "Exporting database …"
# shellcheck disable=SC2086
remote "cd $(shquote \"$WP_PATH\") && $wp_cmd db export $(shquote \"$DUMP_NAME\") --add-drop-table --allow-root" \
  || die "database export failed"
log "DB exported → $WP_PATH/$DUMP_NAME"

# ── 2) archive ──────────────────────────────────────────────────────────────
RC_CLEANUP_REMOTE_ZIP="${RC_CLEANUP_REMOTE_ZIP:-yes}"
step "Archiving site files on server …"
# shellcheck disable=SC2086
remote "
  cd $(shquote \"$WP_PATH\") &&
  zip -r -q $(shquote \"$REMOTE_ZIP\") . -x '*.git/*' -x 'node_modules/*' -x 'wp-content/cache/*' -x 'wp-content/uploads/cache/*'
" || { # shellcheck disable=SC2086
  remote "rm -rf $(shquote \"$REMOTE_ZIP_DIR\")" 2>/dev/null || true; die "remote zip failed"; }

step "Downloading $FILE …"
if scp -P "$SSH_PORT" -i "$SSH_KEY" \
     -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
     "$SSH_HOST:$REMOTE_ZIP" "$DOWNLOADS_DIR/$FILE"; then
  log "Downloaded → $DOWNLOADS_DIR/$FILE"
else
  # shellcheck disable=SC2086
  remote "rm -rf $(shquote \"$REMOTE_ZIP_DIR\")" 2>/dev/null || true
  die "scp download failed"
fi

if [ "$RC_CLEANUP_REMOTE_ZIP" = "yes" ]; then
  # shellcheck disable=SC2086
  remote "rm -rf $(shquote \"$REMOTE_ZIP_DIR\")" || warn "could not remove remote temp dir"
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
  # shellcheck disable=SC2086
  remote "rm -f $(shquote \"$WP_PATH/$DUMP_NAME\")" || warn "could not remove DB dump"
fi

# ── done ────────────────────────────────────────────────────────────────────
echo >&2
update_status "$SITE_KEY" "backed_up" "ok" "zip=$DOWNLOADS_DIR/$FILE"
log "Backup complete: $DOWNLOADS_DIR/$FILE"
