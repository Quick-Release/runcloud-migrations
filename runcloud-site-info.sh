#!/usr/bin/env bash
#
# runcloud-site-info.sh
# ----------------------------------------------------------------------------
# Connects to a RunCloud server, discovers WordPress installs, and prints a
# compact inventory: path, domain, WordPress version, PHP version, database
# prefix, and rough sizes. Use this to decide which Ploi server (modern vs
# legacy PHP) is the right target for each site.
#
# Interactive:
#   ./runcloud-site-info.sh
# Non-interactive / batch:
#   RC_USER=... RC_IP=... BATCH=1 ./runcloud-site-info.sh
#
# Output is tab-separated and also saved to config/sites/<user>_<ip>.tsv.
# ----------------------------------------------------------------------------

set -euo pipefail

# quick help before any prompts
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

command -v ssh >/dev/null 2>&1 || die "missing required local tool: ssh"

RC_USER="${RC_USER:-$(ask 'SSH username')}"
[ -n "$RC_USER" ] || die "username is required"
RC_IP="${RC_IP:-$(ask 'Server IP address')}"
[ -n "$RC_IP" ] || die "IP address is required"

SERVER_CONF="$SERVERS_DIR/$(safe_name "${RC_USER}_${RC_IP}").env"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="${SSH_PORT:-22}"
if [ -f "$SERVER_CONF" ]; then
  # shellcheck source=/dev/null
  . "$SERVER_CONF"
  log "Loaded cached server profile: $SERVER_CONF"
  SSH_PORT="${SSH_PORT:-${PORT:-22}}"
fi

SSH_HOST="$RC_USER@$RC_IP"
SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30
          -o ConnectTimeout=15)

# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$1"; }

step "Connecting to $SSH_HOST:$SSH_PORT …"
# shellcheck disable=SC2016
conn=$(remote 'printf "ok %s@%s" "$(whoami)" "$(hostname)"' 2>&1) || \
  die "SSH connection failed: $conn"
log "Connected: ${conn#ok }"

# ensure wp-cli is available (reuse cached WP_CMD or install)
WP_CMD=""
if [ -f "$SERVER_CONF" ]; then
  # shellcheck source=/dev/null
  . "$SERVER_CONF"
fi
if [ -z "$WP_CMD" ]; then
  step "Probing for wp-cli …"
  # shellcheck disable=SC2016
  probe=$(remote '
    echo "HAVE_WP=$(command -v wp >/dev/null 2>&1 && echo yes || echo no)"
    echo "HAVE_PHP=$(command -v php >/dev/null 2>&1 && echo yes || echo no)"
    for c in /usr/local/bin/wp-cli.phar /usr/bin/wp-cli.phar /opt/wp-cli.phar "$HOME/wp-cli.phar"; do
      [ -f "$c" ] && { echo "WP_PHAR=$c"; break; }
    done
  ') || die "capability probe failed"
  declare -A P
  while IFS='=' read -r k v; do [ -n "$k" ] && P["$k"]="$v"; done <<< "$probe"
  if [ "${P[HAVE_WP]:-no}" = "yes" ]; then
    WP_CMD="wp"
  elif [ -n "${P[WP_PHAR]:-}" ]; then
    WP_CMD="php ${P[WP_PHAR]}"
  elif [ "${P[HAVE_PHP]:-no}" = "yes" ]; then
    # shellcheck disable=SC2016
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
    die "neither wp-cli nor php is available on the server"
  fi
fi

step "Searching for WordPress installs …"
# shellcheck disable=SC2016
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
[ -n "$candidates" ] || die "no WordPress installs found"

mapfile -t cand_arr <<< "$candidates"

OUT="$CONFIG_DIR/sites/$(safe_name "${RC_USER}_${RC_IP}").tsv"
mkdir -p "$(dirname "$OUT")"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "path" "domain" "wp_version" "php_version" "db_prefix" "db_size" "files_size" "php_binary"
  for WP_PATH in "${cand_arr[@]}"; do
    wpver=$(remote "cd $(shquote "$WP_PATH") && $WP_CMD core version 2>/dev/null" || true)
    [ -n "$wpver" ] || { warn "wp-cli could not read $WP_PATH — skipping"; continue; }

    siteurl=$(remote "cd $(shquote "$WP_PATH") && $WP_CMD option get siteurl 2>/dev/null" || true)
    domain="${siteurl#*://}"; domain="${domain%%/*}"; domain="${domain%%:*}"
    domain="$(safe_domain "$domain")"

    # shellcheck disable=SC2086
    dbprefix=$(remote "cd $(shquote \"$WP_PATH\") && $WP_CMD config get table_prefix 2>/dev/null" || true)

    phpbin=$(remote "command -v php 2>/dev/null || true") || true
    phpver=""
    if [ -n "$phpbin" ]; then
      phpver=$(remote "$phpbin -v 2>/dev/null | head -1 | awk '{print \$2}'" || true)
    fi

    # rough sizes
    # shellcheck disable=SC2086
    dbsize=$(remote "cd $(shquote \"$WP_PATH\") && $WP_CMD db size --allow-root 2>/dev/null | tail -1 | awk '{print \$1}'" || true)
    # shellcheck disable=SC2086
    filesize=$(remote "du -sb $(shquote \"$WP_PATH\") 2>/dev/null | awk '{print \$1}'" || true)
    # shellcheck disable=SC2086
    [ -n "$filesize" ] && filesize="$(human_bytes \"$filesize\")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$WP_PATH" "$domain" "$wpver" "${phpver:-unknown}" "${dbprefix:-wp_}" "${dbsize:-unknown}" "${filesize:-unknown}" "${phpbin:-unknown}"
  done
} > "$OUT"

log "Inventory written to $OUT"
echo
cat "$OUT"
