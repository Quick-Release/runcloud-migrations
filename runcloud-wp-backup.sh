#!/usr/bin/env bash
#
# runcloud-wp-backup.sh
# ----------------------------------------------------------------------------
# Connects to a RunCloud server over SSH, finds a WordPress install (wp-cli),
# exports its database, archives the whole site, and downloads it to ./downloads
# as <domain>_<timestamp>.zip — ready to import on ploi.io.
#
# Designed to be run once per site. It asks for the SSH username + IP each run,
# probes the server once (is `wp` available? is `zip` available? which PHP?)
# and caches those answers in ./config/servers/<user>_<ip>.env so re-runs are
# instant. WordPress path is auto-detected each run (a server may host many).
#
# Everything is also overridable non-interactively via env vars, so you can
# batch all ~50 sites later:
#   RC_USER=... RC_IP=... DOMAIN=... BATCH=1 ./runcloud-wp-backup.sh
# (BATCH=1 makes every prompt accept its default — see batch-migrate.sh.)
#
# ----------------------------------------------------------------------------

set -euo pipefail

# ── paths & defaults ────────────────────────────────────────────────────────
# shared helpers, paths, and .env loader (auto-loads ./lib/common.sh → ./.env)
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WORKSPACE="$PROJECT_ROOT"
DOWNLOADS="$DOWNLOADS_DIR"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"   # private key (NOT the .pub)
SSH_PORT="${SSH_PORT:-22}"

# (download/config/servers/logs dirs are created by lib/common.sh)

# ── pretty output ───────────────────────────────────────────────────────────
# (colors + log/warn/die/step provided by lib/common.sh)

# ── small helpers ───────────────────────────────────────────────────────────
# (shquote / ask / ask_yn / safe_name / trim provided by lib/common.sh)

# ── sanity checks ───────────────────────────────────────────────────────────
[ -f "$SSH_KEY" ] || die "SSH private key not found: $SSH_KEY (set SSH_KEY=...)"
for bin in ssh scp rsync zip; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required local tool: $bin"
done

# ── gather connection details ───────────────────────────────────────────────
RC_USER="${RC_USER:-$(ask 'SSH username')}"
[ -n "$RC_USER" ] || die "username is required"
RC_IP="${RC_IP:-$(ask 'Server IP address')}"
[ -n "$RC_IP" ] || die "IP address is required"
SSH_PORT="${SSH_PORT:-$(ask 'SSH port' "$SSH_PORT")}"

SSH_HOST="$RC_USER@$RC_IP"
SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30
          -o ConnectTimeout=15)
SCP_OPTS=(-i "$SSH_KEY" -P "$SSH_PORT"
          -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=15)
RSYNC_E="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30"

# run a command string on the remote host. The string is built locally and sent as
# ONE arg, so $HOME / $(whoami) / ${HOME:-/tmp} etc. are expanded by the REMOTE
# shell — that is intentional and required for the probes below.
# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$1"; }

# ── per-server cached capabilities ──────────────────────────────────────────
SERVER_CONF="$SERVERS_DIR/$(safe_name "${RC_USER}_${RC_IP}").env"

# load cache if present (PORT, WP_CMD, HAVE_ZIP, HAVE_RSYNC, PHP_BIN)
HAVE_ZIP=""; HAVE_RSYNC=""; WP_CMD=""; PHP_BIN=""
if [ -f "$SERVER_CONF" ]; then
  # shellcheck source=/dev/null
  . "$SERVER_CONF"
  log "Loaded cached server profile: $SERVER_CONF"
fi

# ── test connection + host key ──────────────────────────────────────────────
step "Connecting to $SSH_HOST:$SSH_PORT …"
# shellcheck disable=SC2016  # expands remotely by design
conn=$(remote 'printf "ok %s@%s" "$(whoami)" "$(hostname)"' 2>&1) || \
  die "SSH connection failed: $conn"
case "$conn" in
  ok\ *) log "Connected: ${conn#ok }" ;;
  *)     die "SSH connection failed: $conn" ;;
esac

# ── capability probe (only if not cached) ───────────────────────────────────
if [ -z "$WP_CMD" ]; then
  step "Probing server (wp-cli / zip / php) …"
  # shellcheck disable=SC2016  # expands remotely by design
  probe=$(remote '
    echo "HAVE_ZIP=$(command -v zip    >/dev/null 2>&1 && echo yes || echo no)"
    echo "HAVE_PHP=$(command -v php    >/dev/null 2>&1 && echo yes || echo no)"
    echo "HAVE_WP=$( command -v wp     >/dev/null 2>&1 && echo yes || echo no)"
    echo "PHP_BIN=$(command -v php 2>/dev/null || true)"
    echo "WP_BIN=$( command -v wp  2>/dev/null || true)"
    for c in /usr/local/bin/wp-cli.phar /usr/bin/wp-cli.phar /opt/wp-cli.phar "$HOME/wp-cli.phar"; do
      [ -f "$c" ] && { echo "WP_PHAR=$c"; break; }
    done
    echo "HAVE_RSYNC=$(command -v rsync >/dev/null 2>&1 && echo yes || echo no)"
  ') || die "capability probe failed"

  # parse key=value lines
  declare -A P
  while IFS='=' read -r k v; do [ -n "$k" ] && P["$k"]="$v"; done <<< "$probe"

  HAVE_ZIP="${P[HAVE_ZIP]:-no}"
  HAVE_RSYNC="${P[HAVE_RSYNC]:-no}"
  PHP_BIN="${P[PHP_BIN]:-}"

  if [ "${P[HAVE_WP]:-no}" = "yes" ]; then
    WP_CMD="wp"
  elif [ -n "${P[WP_PHAR]:-}" ]; then
    [ "${P[HAVE_PHP]:-no}" = "yes" ] || die "wp-cli phar found but no php on PATH"
    WP_CMD="php ${P[WP_PHAR]}"
  elif [ "${P[HAVE_PHP]:-no}" = "yes" ]; then
    warn "wp-cli not installed — downloading wp-cli.phar to \$HOME …"
    # shellcheck disable=SC2016  # expands remotely by design
    remote '
      cd "$HOME" || exit 1
      if command -v curl >/dev/null 2>&1; then
        curl -sS -o wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
      else
        wget -q -O wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
      fi && chmod +x wp-cli.phar && echo ok
    ' | grep -q ok || die "failed to download wp-cli.phar"
    WP_CMD="php \$HOME/wp-cli.phar"
  else
    die "neither wp-cli nor php is available on the server — cannot export the DB"
  fi

  # persist
  {
    echo "# auto-generated $(date -u +%FT%TZ)  — safe to delete to force re-probe"
    echo "PORT=$(shquote "$SSH_PORT")"
    echo "WP_CMD=$(shquote "$WP_CMD")"
    echo "HAVE_ZIP=$(shquote "$HAVE_ZIP")"
    echo "HAVE_RSYNC=$(shquote "$HAVE_RSYNC")"
    echo "PHP_BIN=$(shquote "$PHP_BIN")"
  } > "$SERVER_CONF"
  log "Saved server profile → $SERVER_CONF"
fi

# ── quick wp-cli sanity test (uses chosen invocation) ───────────────────────
# done after we know the path below; placeholder note.

# ── auto-detect WordPress path ──────────────────────────────────────────────
step "Searching for WordPress installs …"
# shellcheck disable=SC2016  # expands remotely by design
WP_FIND='
for root in "$HOME" /var/www /var/www/html /srv /webapps /usr/share/nginx/html /home; do
  [ -d "$root" ] || continue
  find "$root" -maxdepth 6 \( -name wp-config.php -o -name wp-cli.yml \) -type f 2>/dev/null
done | sort -u | while read -r f; do
  d=$(dirname "$f")
  { [ -f "$d/wp-settings.php" ] || [ -f "$d/wp-includes/version.php" ]; } && printf "%s\n" "$d"
done | sort -u
'
candidates=$(remote "$WP_FIND" || true)
[ -n "$candidates" ] || die "no WordPress installs found; set path manually (edit WP_PATH) and re-run"

mapfile -t cand_arr <<< "$candidates"
if [ "${#cand_arr[@]}" -eq 1 ]; then
  WP_PATH="${cand_arr[0]}"
else
  echo "Multiple WordPress installs found:" >&2
  for i in "${!cand_arr[@]}"; do printf '  %d) %s\n' "$((i+1))" "${cand_arr[$i]}" >&2; done
  sel=$(ask 'Pick one (number)' "1")
  case "$sel" in
    ''|*[!0-9]*) die "invalid selection: $sel" ;;
  esac
  if ! { [ "$sel" -ge 1 ] && [ "$sel" -le "${#cand_arr[@]}" ]; }; then
    die "out of range: $sel"
  fi
  WP_PATH="${cand_arr[$((sel-1))]}"
fi
log "WordPress path: $WP_PATH"

# ── verify wp-cli works against this install ────────────────────────────────
step "Verifying wp-cli can read this site …"
wpver=$(remote "cd $(shquote "$WP_PATH") && $WP_CMD core version 2>/dev/null" || true)
[ -n "$wpver" ] || die "wp-cli could not read the site at $WP_PATH (check PHP/DB perms)"
log "wp-cli OK (WordPress $wpver)"

# ── detect domain for the filename ──────────────────────────────────────────
step "Detecting site URL …"
siteurl=$(remote "cd $(shquote "$WP_PATH") && $WP_CMD option get siteurl 2>/dev/null" || true)
detected="${siteurl#*://}"; detected="${detected%%/*}"; detected="${detected%%:*}"
DOMAIN="${DOMAIN:-$(ask 'Domain for the filename' "${detected:-}")}"
[ -n "$DOMAIN" ] || die "a domain is required for the filename"
DOMAIN="$(printf '%s' "$DOMAIN" | tr -c 'A-Za-z0-9.-' '-')"
log "Domain: $DOMAIN"

# ── names & plan ────────────────────────────────────────────────────────────
stamp=$(date +%Y%m%d-%H%M%S)
FILE="${DOMAIN}_${stamp}.zip"
DUMP_NAME="db_export_${stamp}.sql"

if [ "$HAVE_ZIP" = "yes" ]; then
  METHOD="remote zip → scp"
else
  [ "$HAVE_RSYNC" = "yes" ] || die "server has neither zip nor rsync — cannot archive"
  METHOD="rsync → local zip"
fi

cat >&2 <<PLAN

${C_B}Backup plan${C_0}
  server   : $SSH_HOST:$SSH_PORT
  wp path  : $WP_PATH
  domain   : $DOMAIN
  db dump  : $DUMP_NAME   (created inside the site, LEFT on server)
  archive  : $FILE
  method   : $METHOD
  save to  : $DOWNLOADS/$FILE
PLAN
ask_yn "Proceed with backup?" y || die "aborted"

# ── 1) export database ──────────────────────────────────────────────────────
step "Exporting database (wp db export) …"
remote "cd $(shquote "$WP_PATH") && $WP_CMD db export $(shquote "$DUMP_NAME") --add-drop-table --allow-root" \
  || die "database export failed"
log "DB exported → $WP_PATH/$DUMP_NAME"

# ── 2) archive ──────────────────────────────────────────────────────────────
if [ "$HAVE_ZIP" = "yes" ]; then
  step "Archiving on server (zip) …"
  # shellcheck disable=SC2016  # expands remotely by design
  tmpdir=$(remote 'mktemp -d "${HOME:-/tmp}/.wpbak.XXXXXX"' || true)
  [ -n "$tmpdir" ] || die "could not create remote temp dir"
  remote "cd $(shquote "$WP_PATH") && zip -r -q $(shquote "$tmpdir/$FILE") ." \
    || { remote "rm -rf $(shquote "$tmpdir")"; die "remote zip failed"; }
  step "Downloading $FILE …"
  if scp "${SCP_OPTS[@]}" "$SSH_HOST:$tmpdir/$FILE" "$DOWNLOADS/$FILE"; then
    log "Downloaded → $DOWNLOADS/$FILE"
    remote "rm -rf $(shquote "$tmpdir")" || warn "could not remove remote temp $tmpdir"
  else
    remote "rm -rf $(shquote "$tmpdir")" || true
    die "scp download failed (remote zip left behind only briefly; sql dump remains at $WP_PATH/$DUMP_NAME)"
  fi
else
  step "Archiving via rsync (no remote zip) …"
  tmplocal="$(mktemp -d "$WORKSPACE/.dl.XXXXXX")"
  trap 'rm -rf "$tmplocal"' EXIT
  if rsync -a --info=progress2 -e "$RSYNC_E" "$SSH_HOST:$WP_PATH/" "$tmplocal/"; then
    ( cd "$tmplocal" && zip -r -q "$DOWNLOADS/$FILE" . ) || die "local zip failed"
    log "Archived → $DOWNLOADS/$FILE"
  else
    die "rsync failed (sql dump still on server at $WP_PATH/$DUMP_NAME)"
  fi
fi

# ── done ────────────────────────────────────────────────────────────────────
echo >&2
log "Backup complete: $DOWNLOADS/$FILE"
if [ "$HAVE_ZIP" = "yes" ]; then
  warn "DB dump left on server: $WP_PATH/$DUMP_NAME"
fi
echo  "Import next: upload $FILE to ploi, extract, import the .sql, fix wp-config DB creds." >&2
