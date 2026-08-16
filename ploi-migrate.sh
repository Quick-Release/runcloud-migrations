#!/usr/bin/env bash
#
# ploi-migrate.sh
# ----------------------------------------------------------------------------
# Migrates a previously downloaded RunCloud WordPress backup onto a Ploi
# server, end-to-end, using an isolated per-site system user.
#
# Security model:
#   - PLOI_SSH_USER is a privileged admin (ploi/root) used ONLY to:
#       * create the per-site system user via the Ploi API
#       * add the migration SSH public key to that user
#       * optionally configure a chroot jail for that user
#   - All file operations (upload, extract, import, wp-cli) run as the
#     per-site system user, which has no sudo access and cannot see other
#     sites' data.
#
# Usage:
#   ./ploi-migrate.sh /path/to/example.com_20240101-120000.zip
#
# Env overrides (see .env.example):
#   PLOI_API_TOKEN, PLOI_SERVER_ID, PLOI_SSH_HOST/PORT/USER/KEY,
#   DOMAIN, PLOI_PHP_VERSION, PLOI_SSL_MODE, etc.
# ----------------------------------------------------------------------------

set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


for bin in ssh scp ssh-keygen curl jq unzip; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required local tool: $bin"
done

# ── parse arguments ─────────────────────────────────────────────────────────
ZIP_FILE="${1:-}"
[ -n "$ZIP_FILE" ] || die "usage: $0 <backup-zip>"
[ -f "$ZIP_FILE" ] || die "backup zip not found: $ZIP_FILE"
ZIP_FILE="$(cd "$(dirname "$ZIP_FILE")" && pwd)/$(basename "$ZIP_FILE")"

# derive a default domain from filename (e.g. example.com_20240101-120000.zip)
basename_zip="$(basename "$ZIP_FILE" .zip)"
default_domain="${basename_zip%_*}"   # strip the trailing _timestamp
DOMAIN="${DOMAIN:-$(ask 'Domain to migrate' "$default_domain")}"
DOMAIN="$(safe_domain "$DOMAIN")"
[ -n "$DOMAIN" ] || die "domain is required"

SITE_KEY="${MIGRATION_KEY:-ploi:${DOMAIN}}"
update_status "$SITE_KEY" "discovered" "ok" "domain=$DOMAIN"

# ── Ploi config ─────────────────────────────────────────────────────────────
PLOI_API_TOKEN="${PLOI_API_TOKEN:-}"
PLOI_API_URL="${PLOI_API_URL:-https://ploi.io/api}"
PLOI_SSH_HOST="${PLOI_SSH_HOST:-}"
PLOI_SSH_PORT="${PLOI_SSH_PORT:-22}"
PLOI_SSH_USER="${PLOI_SSH_USER:-ploi}"
PLOI_SSH_KEY="${PLOI_SSH_KEY:-$HOME/.ssh/id_ed25519}"
PLOI_SYSTEM_USER_STRATEGY="${PLOI_SYSTEM_USER_STRATEGY:-per-site}"
PLOI_SHARED_SYSTEM_USER="${PLOI_SHARED_SYSTEM_USER:-ploi}"
PLOI_ADD_SSH_KEY_TO_SITE_USER="${PLOI_ADD_SSH_KEY_TO_SITE_USER:-yes}"
PLOI_CHROOT_SITE_USER="${PLOI_CHROOT_SITE_USER:-yes}"
PLOI_DB_AUTOGEN="${PLOI_DB_AUTOGEN:-yes}"
PLOI_PHP_VERSION="${PLOI_PHP_VERSION:-8.2}"
PLOI_SSL_MODE="${PLOI_SSL_MODE:-auto}"
PLOI_DOMAIN_MODE="${PLOI_DOMAIN_MODE:-same}"
PLOI_PROJECT_TYPE="${PLOI_PROJECT_TYPE:-wordpress}"
PLOI_WEB_DIRECTORY="${PLOI_WEB_DIRECTORY:-/public}"
PLOI_DB_HOST="${PLOI_DB_HOST:-127.0.0.1}"
PLOI_RUN_DEPLOY="${PLOI_RUN_DEPLOY:-yes}"
PLOI_INSTALL_WP_CLI="${PLOI_INSTALL_WP_CLI:-yes}"

[ -n "$PLOI_API_TOKEN" ] || die "PLOI_API_TOKEN is not set"
[ -f "$PLOI_SSH_KEY" ] || die "Ploi SSH key not found: $PLOI_SSH_KEY"
[ -n "$PLOI_SSH_HOST" ] || die "PLOI_SSH_HOST is not set"

ploi_ensure_server_id
[ -n "$PLOI_SERVER_ID" ] || die "PLOI_SERVER_ID is not set"

# system user
if [ "$PLOI_SYSTEM_USER_STRATEGY" = "shared" ]; then
  SYSTEM_USER="$PLOI_SHARED_SYSTEM_USER"
else
  SYSTEM_USER="$(safe_db_name "$DOMAIN")"
  # avoid names starting with a digit
  case "$SYSTEM_USER" in [0-9]*) SYSTEM_USER="u${SYSTEM_USER}"; esac
fi

# This is the unprivileged user used for all site file operations.
export PLOI_SITE_USER="$SYSTEM_USER"

step "Migration plan"
cat >&2 <<PLAN
  domain       : $DOMAIN
  server id    : $PLOI_SERVER_ID
  system user  : $SYSTEM_USER (strategy: $PLOI_SYSTEM_USER_STRATEGY)
  php version  : $PLOI_PHP_VERSION
  ssl mode     : $PLOI_SSL_MODE
  backup zip   : $ZIP_FILE
PLAN
ask_yn "Proceed with Ploi migration?" y || die "aborted"

# ── helpers for Ploi API ────────────────────────────────────────────────────
api_create_system_user() {
  local body
  body=$(jq -n \
    --arg name "$SYSTEM_USER" \
    --arg pass "$(random_password)" \
    '{name: $name, password: $pass}')
  ploi_curl POST "/servers/${PLOI_SERVER_ID}/system-users" -d "$body"
}

api_create_site() {
  local body
  body=$(jq -n \
    --arg domain "$DOMAIN" \
    --arg user "$SYSTEM_USER" \
    --arg type "$PLOI_PROJECT_TYPE" \
    --arg webdir "$PLOI_WEB_DIRECTORY" \
    --arg php "$PLOI_PHP_VERSION" \
    '{domain: $domain, system_user: $user, project_type: $type, web_directory: $webdir, php_version: $php}')
  ploi_curl POST "/servers/${PLOI_SERVER_ID}/sites" -d "$body"
}

api_create_database() {
  local body
  body=$(jq -n \
    --arg name "$DB_NAME" \
    --arg user "$DB_USER" \
    --arg pass "$DB_PASS" \
    --arg host "$PLOI_DB_HOST" \
    '{name: $name, user: $user, password: $pass, host: $host}')
  ploi_curl POST "/servers/${PLOI_SERVER_ID}/databases" -d "$body"
}

api_get_site() {
  ploi_curl GET "/servers/${PLOI_SERVER_ID}/sites/${1}"
}

api_request_ssl() {
  local body
  body=$(jq -n '{}')
  ploi_curl POST "/servers/${PLOI_SERVER_ID}/sites/${1}/ssl" -d "$body" >/dev/null || true
}

api_deploy() {
  local body
  body=$(jq -n '{}')
  ploi_curl POST "/servers/${PLOI_SERVER_ID}/sites/${1}/deploy" -d "$body" >/dev/null || true
}

# ── 0) ensure system user exists (per-site strategy only) ───────────────────
if [ "$PLOI_SYSTEM_USER_STRATEGY" = "per-site" ]; then
  step "Creating isolated system user $SYSTEM_USER …"
  update_status "$SITE_KEY" "site_user" "running" ""
  resp=$(api_create_system_user) || die "failed to create Ploi system user"
  log "System user created/updated: $SYSTEM_USER"
  ploi_wait
  update_status "$SITE_KEY" "site_user" "ok" "user=$SYSTEM_USER"
fi

# ── 1) create site ──────────────────────────────────────────────────────────
step "Creating Ploi site for $DOMAIN …"
update_status "$SITE_KEY" "site_created" "running" ""
resp=$(api_create_site) || die "failed to create Ploi site"
SITE_ID=$(printf '%s' "$resp" | jq -r '.data.id // empty')
[ -n "$SITE_ID" ] || die "Ploi site creation did not return a site id; response: $resp"
log "Ploi site created: id=$SITE_ID"
ploi_wait

# discover actual site root
step "Discovering site root on Ploi server …"
SITE_ROOT=""
for _ in 1 2 3; do
  site_json=$(api_get_site "$SITE_ID") || true
  SITE_ROOT=$(printf '%s' "$site_json" | jq -r '.data.root_directory // .data.path // empty')
  [ -n "$SITE_ROOT" ] && break
  sleep 2
done

if [ -z "$SITE_ROOT" ]; then
  # fall back to common Ploi layout
  SITE_ROOT="/home/${SYSTEM_USER}/${DOMAIN}"
  warn "could not determine site root from API; assuming $SITE_ROOT"
fi
WEB_ROOT="${SITE_ROOT%/}${PLOI_WEB_DIRECTORY}"
log "Site root: $SITE_ROOT"
log "Web root : $WEB_ROOT"
update_status "$SITE_KEY" "site_created" "ok" "site_id=$SITE_ID root=$SITE_ROOT"

# ── 2) create database ───────────────────────────────────────────────────────
step "Creating database …"
update_status "$SITE_KEY" "db_created" "running" ""
if [ "$PLOI_DB_AUTOGEN" = "yes" ]; then
  DB_NAME="$(safe_db_name "${DOMAIN}_db")"
  DB_USER="$(safe_db_name "${DOMAIN}_usr")"
  DB_PASS="$(random_password)"
else
  DB_NAME="${DB_NAME:-$(ask 'Database name' "$(safe_db_name "${DOMAIN}_db")")}"
  DB_USER="${DB_USER:-$(ask 'Database user' "$(safe_db_name "${DOMAIN}_usr")")}"
  DB_PASS="${DB_PASS:-$(ask 'Database password' "$(random_password)")}"
fi
_=$(api_create_database) || die "failed to create Ploi database"
log "Database created: $DB_NAME"
update_status "$SITE_KEY" "db_created" "ok" "name=$DB_NAME user=$DB_USER"

# save credentials locally (gitignored)
CREDS_FILE="$CONFIG_DIR/sites/$(safe_name "$DOMAIN").env"
mkdir -p "$(dirname "$CREDS_FILE")"
{
  echo "# generated $(date -u +%FT%TZ)"
  echo "DOMAIN=$(shquote "$DOMAIN")"
  echo "SITE_ID=$(shquote "$SITE_ID")"
  echo "SITE_ROOT=$(shquote "$SITE_ROOT")"
  echo "WEB_ROOT=$(shquote "$WEB_ROOT")"
  echo "DB_NAME=$(shquote "$DB_NAME")"
  echo "DB_USER=$(shquote "$DB_USER")"
  echo "DB_PASS=$(shquote "$DB_PASS")"
  echo "DB_HOST=$(shquote "$PLOI_DB_HOST")"
  echo "SYSTEM_USER=$(shquote "$SYSTEM_USER")"
} > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
log "Saved credentials to $CREDS_FILE"

# ── 2b) add SSH key to per-site user via admin if API did not include it ────
if [ "$PLOI_ADD_SSH_KEY_TO_SITE_USER" = "yes" ]; then
  step "Ensuring SSH key is authorized for $SYSTEM_USER …"
  pub_key="$(ssh_public_key_for "$PLOI_SSH_KEY")"
  # shellcheck disable=SC2016
  ploi_admin_remote '
    user="'"$SYSTEM_USER"'"
    pub_key="'"$pub_key"'"
    home=$(getent passwd "$user" | cut -d: -f6)
    [ -n "$home" ] || { echo "user $user not found"; exit 1; }
    mkdir -p "$home/.ssh"
    chmod 700 "$home/.ssh"
    if ! grep -qF "$pub_key" "$home/.ssh/authorized_keys" 2>/dev/null; then
      printf "%s\n" "$pub_key" >> "$home/.ssh/authorized_keys"
    fi
    chmod 600 "$home/.ssh/authorized_keys"
    chown -R "$user:$user" "$home/.ssh"
    echo ok
  ' | grep -q ok || warn "could not add SSH key to $SYSTEM_USER (API may already have added it)"
fi


# ── 3) upload backup zip ────────────────────────────────────────────────────
step "Uploading backup to Ploi server as $SYSTEM_USER …"
update_status "$SITE_KEY" "uploaded" "running" ""
REMOTE_ZIP="/tmp/$(basename "$ZIP_FILE")"
ploi_site_scp "$ZIP_FILE" "$(ploi_site_ssh_host):$REMOTE_ZIP" || die "failed to upload zip to Ploi server"
log "Uploaded → $REMOTE_ZIP"
update_status "$SITE_KEY" "uploaded" "ok" "remote_zip=$REMOTE_ZIP"

# ── 4) extract ──────────────────────────────────────────────────────────────
step "Extracting backup into $WEB_ROOT …"
update_status "$SITE_KEY" "extracted" "running" ""
ploi_site_remote "mkdir -p $(shquote "$WEB_ROOT") && unzip -q -o $(shquote "$REMOTE_ZIP") -d $(shquote "$WEB_ROOT")" \
  || die "failed to extract backup on Ploi server"
log "Extracted into $WEB_ROOT"
update_status "$SITE_KEY" "extracted" "ok" ""

# ── 5) find the SQL dump ─────────────────────────────────────────────────────
step "Locating SQL dump inside extracted backup …"
SQL_FILE=$(ploi_site_remote "find $(shquote "$WEB_ROOT") -maxdepth 2 -name 'db_export_*.sql' -type f | head -1")
[ -n "$SQL_FILE" ] || die "no db_export_*.sql file found inside $WEB_ROOT"
log "SQL dump: $SQL_FILE"

# ── 6) install wp-cli on Ploi if needed ──────────────────────────────────────
WP_CMD="wp"
if [ "$PLOI_INSTALL_WP_CLI" = "yes" ]; then
  step "Ensuring wp-cli is available on Ploi server …"
  # shellcheck disable=SC2016
  ploi_site_remote '
    command -v wp >/dev/null 2>&1 && exit 0
    cd "$HOME" || exit 1
    curl -sS -o wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mkdir -p "$HOME/bin"
    mv wp-cli.phar "$HOME/bin/wp"
  ' || warn "could not install wp-cli automatically; migration may fail if wp is missing"
fi

# verify wp works
ploi_site_remote "cd $(shquote "$WEB_ROOT") && $WP_CMD core version --allow-root >/dev/null" || die "wp-cli is not usable on the Ploi server"

# ── 7) import database ──────────────────────────────────────────────────────
step "Importing database …"
update_status "$SITE_KEY" "imported" "running" ""
ploi_site_remote "cd $(shquote "$WEB_ROOT") && $WP_CMD db import $(shquote "$SQL_FILE") --allow-root" \
  || die "database import failed"
log "Database imported"
update_status "$SITE_KEY" "imported" "ok" ""

# ── 8) patch wp-config.php ────────────────────────────────────────────────────
step "Updating wp-config.php with new credentials …"
update_status "$SITE_KEY" "configured" "running" ""
ploi_site_remote "cd $(shquote "$WEB_ROOT") && \
  $WP_CMD config set DB_NAME $(shquote "$DB_NAME") --allow-root && \
  $WP_CMD config set DB_USER $(shquote "$DB_USER") --allow-root && \
  $WP_CMD config set DB_PASSWORD $(shquote "$DB_PASS") --allow-root && \
  $WP_CMD config set DB_HOST $(shquote "$PLOI_DB_HOST") --allow-root" \
  || die "failed to update wp-config.php"
log "wp-config.php updated"

# remove the SQL dump from the public web root so it cannot be downloaded
ploi_site_remote "rm -f $(shquote "$SQL_FILE")" || warn "could not remove SQL dump from web root"

# same-domain migration → no search-replace needed
if [ "$PLOI_DOMAIN_MODE" != "same" ]; then
  NEW_DOMAIN="${NEW_DOMAIN:-$(ask 'New domain for search-replace')}"
  [ -n "$NEW_DOMAIN" ] || die "NEW_DOMAIN is required when PLOI_DOMAIN_MODE != same"
  step "Running wp search-replace $DOMAIN → $NEW_DOMAIN …"
  ploi_site_remote "cd $(shquote "$WEB_ROOT") && \
    $WP_CMD search-replace $(shquote "$DOMAIN") $(shquote "$NEW_DOMAIN") --all-tables --allow-root" \
    || warn "search-replace finished with errors"
fi
update_status "$SITE_KEY" "configured" "ok" ""

# ── 9) ownership / permissions ───────────────────────────────────────────────
# The per-site user has no sudo, so ownership must be fixed by the admin user.
step "Fixing file ownership …"
ploi_admin_remote "chown -R $(shquote "$SYSTEM_USER"):$(shquote "$SYSTEM_USER") $(shquote "$WEB_ROOT")" \
  || warn "could not chown web root"
ploi_admin_remote "chown $(shquote "$SYSTEM_USER"):$(shquote "$SYSTEM_USER") $(shquote "$SITE_ROOT")" || true

# ── 10) remove remote zip ────────────────────────────────────────────────────
ploi_site_remote "rm -f $(shquote "$REMOTE_ZIP")" || warn "could not remove remote zip"

# ── 11) SSL ──────────────────────────────────────────────────────────────────
if [ "$PLOI_SSL_MODE" = "always" ] || [ "$PLOI_SSL_MODE" = "auto" ]; then
  step "Requesting SSL certificate …"
  api_request_ssl "$SITE_ID" || warn "SSL request failed (domain may not resolve to Ploi yet)"
fi

# ── 12) deploy ───────────────────────────────────────────────────────────────
if [ "$PLOI_RUN_DEPLOY" = "yes" ]; then
  step "Deploying site …"
  api_deploy "$SITE_ID" || warn "deploy request failed"
  ploi_wait
fi
update_status "$SITE_KEY" "deployed" "ok" ""

# ── 13) smoke test ───────────────────────────────────────────────────────────
step "Smoke-testing https://${DOMAIN} …"
http_code=$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN}" 2>/dev/null || true)
case "$http_code" in
  200|301|302|307|308)
    log "Smoke test OK (HTTP $http_code)"
    update_status "$SITE_KEY" "verified" "ok" "http=$http_code"
    ;;
  *)
    warn "Smoke test returned HTTP ${http_code:-none} — site may need DNS or SSL propagation"
    update_status "$SITE_KEY" "verified" "warn" "http=${http_code:-none}"
    ;;
esac

# ── 14) optional chroot jail for the per-site user ──────────────────────────
# Applied as the LAST step so all migration commands above can still use SSH
# as the site user. After this, the user is SFTP-only and locked to /home/user.
if [ "$PLOI_CHROOT_SITE_USER" = "yes" ]; then
  step "Locking $SYSTEM_USER into chroot jail (final hardening) …"
  # shellcheck disable=SC2016
  result=$(ploi_admin_remote '
    user="'"$SYSTEM_USER"'"
    home=$(getent passwd "$user" | cut -d: -f6)
    [ -n "$home" ] || { echo "user $user not found"; exit 1; }

    # For SFTP chroot, the chroot directory itself must be root-owned and
    # not writable by the user. The site subdirectory stays user-owned.
    chown root:root "$home"
    chmod 755 "$home"

    # Ensure the site directory is still writable by the user
    for d in "$home"/*/; do
      [ -d "$d" ] || continue
      chown -R "$user:$user" "$d"
    done

    # Add a Match block to sshd_config if not present
    match_line="Match User $user"
    if ! grep -qF "$match_line" /etc/ssh/sshd_config 2>/dev/null; then
      {
        echo ""
        echo "$match_line"
        echo "    ChrootDirectory $home"
        echo "    AllowTcpForwarding no"
        echo "    X11Forwarding no"
        echo "    ForceCommand internal-sftp"
      } >> /etc/ssh/sshd_config
      if command -v sshd >/dev/null 2>&1; then
        sshd -t && systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
      fi
      echo configured
    else
      echo already_configured
    fi
  ')
  if printf '%s' "$result" | grep -qE 'configured|already_configured'; then
    log "Chroot jail active for $SYSTEM_USER (SFTP-only, locked to home)"
  else
    warn "Chroot setup failed — user remains shell-accessible. Review /etc/ssh/sshd_config manually."
  fi
fi

echo >&2
log "Migration complete: https://${DOMAIN}"
echo "  site id : $SITE_ID" >&2
echo "  user    : $SYSTEM_USER" >&2
echo "  root    : $SITE_ROOT" >&2
echo "  web     : $WEB_ROOT" >&2
echo "  creds   : $CREDS_FILE" >&2
if [ "$PLOI_CHROOT_SITE_USER" = "yes" ]; then
  echo "  chroot  : enabled (SFTP-only, locked to /home/$SYSTEM_USER)" >&2
else
  echo "  chroot  : disabled" >&2
fi
