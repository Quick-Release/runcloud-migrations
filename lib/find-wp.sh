#!/usr/bin/env bash
#
# lib/find-wp.sh
# ----------------------------------------------------------------------------
# Generic SSH probe: given SSH_HOST (user@host), SSH_KEY, SSH_PORT and DOMAIN,
# find a WordPress install on the remote server whose siteurl matches DOMAIN.
#
# Outputs key=value lines:
#   status=ok|not_found|unreachable|error
#   wp_path=/path/to/wordpress
#   siteurl=https://example.com
#   wp_version=6.5
#   php_version=8.2
#   db_prefix=wp_
#   db_name=example_db
#
# Exit code is always 0 when the probe itself ran; callers should parse status.
#
# Env:
#   FIND_WP_ROOTS  optional space-separated list overriding the default search
#                 roots. Default expands on the remote ("$HOME", /var/www,
#                 ...); the override is expanded locally before sending.
# ----------------------------------------------------------------------------

set -uo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


SSH_HOST="${SSH_HOST:-}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="${SSH_PORT:-22}"
DOMAIN="${DOMAIN:-}"

[ -n "$SSH_HOST" ] || { echo "status=error"; echo "detail=SSH_HOST is not set"; exit 0; }
[ -n "$DOMAIN" ] || { echo "status=error"; echo "detail=DOMAIN is not set"; exit 0; }
[ -f "$SSH_KEY" ] || { echo "status=error"; echo "detail=SSH key not found: $SSH_KEY"; exit 0; }

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30
          -o ConnectTimeout=15
          -o BatchMode=yes)

# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$1"; }

# test connection
# shellcheck disable=SC2016
if ! remote 'echo ok' >/dev/null 2>&1; then
  echo "status=unreachable"
  echo "detail=SSH connection failed to $SSH_HOST"
  exit 0
fi

# ensure wp-cli is available
# shellcheck disable=SC2016
wp_cmd=$(remote '
  if command -v wp >/dev/null 2>&1; then
    echo wp
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
    echo none
  else
    echo none
  fi
')

if [ "$wp_cmd" = "none" ] || [ -z "$wp_cmd" ]; then
  echo "status=error"
  echo "detail=wp-cli (or php) not available on $SSH_HOST"
  exit 0
fi
# Escape $ so that $HOME (and similar) is expanded by the REMOTE shell, not locally.
wp_cmd=$(printf '%s' "$wp_cmd" | sed 's/\$/\\$/g')

# find WordPress installs under common roots (or $FIND_WP_ROOTS when set;
# the test suite uses FIND_WP_ROOTS to keep the search hermetic)
if [ -n "${FIND_WP_ROOTS:-}" ]; then
  roots_expr=""
  # shellcheck disable=SC2086  # word-splitting is the point
  for root in $FIND_WP_ROOTS; do
    roots_expr+="$(shquote "$root") "
  done
else
  # shellcheck disable=SC2016  # "$HOME" must expand on the remote, not here
  roots_expr='"$HOME" /var/www /var/www/html /srv /webapps /usr/share/nginx/html /home /opt /data/coolify/services /var/web'
fi
paths=$(remote "
  for root in $roots_expr; do
    [ -d \$root ] || continue
    find \"\$root\" -maxdepth 7 \( -name wp-config.php -o -name wp-cli.yml \) -type f 2>/dev/null
  done | sort -u | while read -r f; do
    d=\$(dirname \"\$f\")
    { [ -f \"\$d/wp-settings.php\" ] || [ -f \"\$d/wp-includes/version.php\" ]; } && printf \"%s\n\" \"\$d\"
  done | sort -u
")

[ -n "$paths" ] || { echo "status=not_found"; exit 0; }

norm_domain() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#^www\.##; s#/.*##' | tr -c 'a-z0-9.-' '-' | tr -s '-' | sed 's/^-//;s/-$//'
}
target_norm=$(norm_domain "$DOMAIN")
target_www_norm=$(norm_domain "www.$DOMAIN")

while IFS= read -r wp_path; do
  [ -n "$wp_path" ] || continue
  # shellcheck disable=SC2016
  siteurl=$(remote "cd $(shquote "$wp_path") && $wp_cmd option get siteurl 2>/dev/null" || true)
  [ -n "$siteurl" ] || continue
  site_norm=$(norm_domain "$siteurl")
  if [ "$site_norm" = "$target_norm" ] || [ "$site_norm" = "$target_www_norm" ]; then
    # shellcheck disable=SC2016
    wp_ver=$(remote "cd $(shquote "$wp_path") && $wp_cmd core version 2>/dev/null" || true)
    # shellcheck disable=SC2016
    db_prefix=$(remote "cd $(shquote "$wp_path") && $wp_cmd config get table_prefix 2>/dev/null" || true)
    # shellcheck disable=SC2016
    db_name=$(remote "cd $(shquote "$wp_path") && $wp_cmd config get DB_NAME 2>/dev/null" || true)
    # shellcheck disable=SC2016
    php_ver=$(remote 'command -v php >/dev/null 2>&1 && php -v 2>/dev/null | head -1 | awk "{print \$2}"' || true)
    echo "status=ok"
    echo "wp_path=$wp_path"
    echo "siteurl=$siteurl"
    echo "wp_version=${wp_ver:-unknown}"
    echo "php_version=${php_ver:-unknown}"
    echo "db_prefix=${db_prefix:-wp_}"
    echo "db_name=${db_name:-unknown}"
    coolify_uuid=""
    if [[ "$wp_path" == /data/coolify/services/* ]]; then
      coolify_uuid="${wp_path#/data/coolify/services/}"
      coolify_uuid="${coolify_uuid%%/*}"
    fi
    [ -n "$coolify_uuid" ] && echo "coolify_service_uuid=$coolify_uuid"
    exit 0
  fi
done <<< "$paths"

echo "status=not_found"
exit 0
