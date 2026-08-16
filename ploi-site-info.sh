#!/usr/bin/env bash
#
# ploi-site-info.sh
# ----------------------------------------------------------------------------
# Connects to a source Ploi server via the Ploi API + SSH, discovers WordPress
# installs, and prints a compact inventory: domain, system user, path,
# WordPress version, PHP version, database prefix, and rough sizes.
#
# Use this to decide which target Ploi server (modern vs legacy PHP) is the
# right destination for each site.
#
# Interactive:
#   ./ploi-site-info.sh
# Non-interactive:
#   PLOI_API_TOKEN=... PLOI_SOURCE_SERVER_ID=... BATCH=1 ./ploi-site-info.sh
#
# Output is tab-separated and saved to config/sites/ploi-<server_id>.tsv.
# ----------------------------------------------------------------------------

set -euo pipefail

# quick help before any prompts
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

command -v ssh >/dev/null 2>&1 || die "missing required local tool: ssh"
command -v jq >/dev/null 2>&1 || die "missing required local tool: jq"

PLOI_SOURCE_SERVER_ID="${PLOI_SOURCE_SERVER_ID:-}"
PLOI_SOURCE_SSH_HOST="${PLOI_SOURCE_SSH_HOST:-}"
PLOI_SOURCE_SSH_PORT="${PLOI_SOURCE_SSH_PORT:-22}"
PLOI_SOURCE_SSH_USER="${PLOI_SOURCE_SSH_USER:-ploi}"
PLOI_SOURCE_SSH_KEY="${PLOI_SOURCE_SSH_KEY:-$HOME/.ssh/id_ed25519}"
PLOI_SOURCE_WEB_DIRECTORY="${PLOI_SOURCE_WEB_DIRECTORY:-/public}"

[ -n "$PLOI_API_TOKEN" ] || die "PLOI_API_TOKEN is not set"
[ -f "$PLOI_SOURCE_SSH_KEY" ] || die "source Ploi SSH key not found: $PLOI_SOURCE_SSH_KEY"
[ -n "$PLOI_SOURCE_SSH_HOST" ] || die "PLOI_SOURCE_SSH_HOST is not set"

# ensure source server id
ploi_ensure_source_server_id

step "Connecting to source Ploi server $(ploi_source_ssh_host):$PLOI_SOURCE_SSH_PORT …"
# shellcheck disable=SC2016
conn=$(ploi_source_remote 'printf "ok %s@%s" "$(whoami)" "$(hostname)"' 2>&1) || \
  die "SSH connection failed: $conn"
case "$conn" in
  ok\ *) log "Connected: ${conn#ok }" ;;
  *)     die "SSH connection failed: $conn" ;;
esac

step "Listing sites via Ploi API …"
sites_json=$(ploi_curl GET "/servers/${PLOI_SOURCE_SERVER_ID}/sites") || die "failed to list sites"
count=$(printf '%s' "$sites_json" | jq '.data | length')
if [ "$count" -eq 0 ]; then
  die "no sites found on source server ${PLOI_SOURCE_SERVER_ID}"
fi

OUT="$CONFIG_DIR/sites/ploi-${PLOI_SOURCE_SERVER_ID}.tsv"
mkdir -p "$(dirname "$OUT")"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "domain" "system_user" "path" "wp_version" "php_version" "db_prefix" "db_size" "files_size" "project_type"

  for i in $(seq 0 $((count - 1))); do
    domain=$(printf '%s' "$sites_json" | jq -r ".data[$i].domain // empty")
    user=$(printf '%s' "$sites_json" | jq -r ".data[$i].system_user // empty")
    root_dir=$(printf '%s' "$sites_json" | jq -r ".data[$i].root_directory // empty")
    php=$(printf '%s' "$sites_json" | jq -r ".data[$i].php_version // empty")
    ptype=$(printf '%s' "$sites_json" | jq -r ".data[$i].project_type // empty")
    [ -n "$domain" ] || continue
    [ -n "$user" ] || continue
    [ -n "$root_dir" ] || root_dir="/home/${user}/${domain}"

    wp_path=""
    wpver=""
    dbprefix=""
    dbsize=""
    filesize=""

    # shellcheck disable=SC2016
    info=$(ploi_source_remote '
      root="'"$root_dir"'"
      web="'"${root_dir%/}${PLOI_SOURCE_WEB_DIRECTORY}"'"
      for d in "$web" "$root" "$root/public_html" "$root/public" "$root/web" "$root/httpdocs"; do
        [ -f "$d/wp-config.php" ] && { printf "WP_PATH=%s\n" "$d"; break; }
      done
      [ -z "${WP_PATH:-}" ] && WP_PATH=$(find "$root" -maxdepth 3 -name wp-config.php -type f 2>/dev/null | head -1)
      [ -z "$WP_PATH" ] && exit 0
      printf "WP_PATH=%s\n" "$WP_PATH"
      if command -v php >/dev/null 2>&1; then
        php -r "require \"$WP_PATH/wp-includes/version.php\"; echo \"WP_VER=\$wp_version\\n\";"
      fi
    ' 2>/dev/null) || true

    wp_path=$(printf '%s' "$info" | sed -n 's/^WP_PATH=//p' | head -1)
    wpver=$(printf '%s' "$info" | sed -n 's/^WP_VER=//p' | head -1)

    if [ -n "$wp_path" ]; then
      # shellcheck disable=SC2016
      dbprefix=$(ploi_source_remote "grep -oE 'table_prefix[^;]+' $(shquote "$wp_path/wp-config.php") 2>/dev/null | sed -n \"s/.*= *['\\\"]\\?\\([A-Za-z0-9_]*\\)['\\\"]\\?.*/\\1/p\" | head -1" 2>/dev/null) || true
      filesize=$(ploi_source_remote "du -sb $(shquote "$wp_path") 2>/dev/null | awk '{print \$1}'" 2>/dev/null) || true
      [ -n "$filesize" ] && filesize="$(human_bytes "$filesize")"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$domain" "$user" "${wp_path:-$root_dir}" "${wpver:-unknown}" "${php:-unknown}" \
      "${dbprefix:-unknown}" "${dbsize:-unknown}" "${filesize:-unknown}" "${ptype:-unknown}"
  done
} > "$OUT"

log "Inventory written to $OUT"
echo
cat "$OUT"
