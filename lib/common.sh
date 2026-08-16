# shellcheck shell=bash
# ============================================================================
# lib/common.sh - shared helpers + .env loader for the runcloud->ploi toolkit.
# Sourced by: runcloud-wp-backup.sh, batch-migrate.sh, ploi-migrate.sh,
#             batch-migrate-ploi.sh
#
# Auto-loads ./<project-root>/.env at source time. Real environment variables
# always take precedence over .env (so `FOO=bar ./script` still wins).
# ============================================================================

# guard against being sourced twice in the same shell
[ -n "${_PI_COMMON_LOADED:-}" ] && return 0
_PI_COMMON_LOADED=1

# project root = parent of this lib/ directory (works from any cwd)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -- .env loader -------------------------------------------------------------
# trim leading/trailing whitespace + CR
_trim() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# load_env <file>  - set KEY=VALUE lines as exported vars; env wins; ~ expanded.
# Supports: comments (#...), blank lines, optional `export ` prefix, and
# surrounding "..." or '...' quotes. NO inline comments after values, and $VAR
# is NOT expanded inside values (use ~/ or absolute paths instead).
load_env() {
  local f="$1" line key val t
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"   # left-trim
    case "$line" in ''|\#*) continue ;; esac   # skip blank / comment lines
    case "$line" in *=*) ;; *) continue ;; esac # need at least one '='
    case "$line" in 'export '*) line="${line#'export '}" ;; esac
    key="$(_trim "${line%%=*}")"
    val="${line#*=}"
    # strip one layer of surrounding quotes
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    val="$(_trim "$val")"
    # expand a leading ~/ (or a bare ~) to $HOME
    t='~'
    case "$val" in
      "$t"/*) val="$HOME/${val#"$t"/}" ;;
      "$t")   val="$HOME" ;;
    esac
    # only assign if not already present in the real environment
    [ -n "${!key+x}" ] || export "$key=$val"
  done < "$f"
}

# load config first, so path defaults below can be overridden by .env
load_env "$PROJECT_ROOT/.env"

# -- paths (overridable via .env / environment) ------------------------------
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$PROJECT_ROOT/downloads}"
CONFIG_DIR="${CONFIG_DIR:-$PROJECT_ROOT/config}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"
SERVERS_DIR="$CONFIG_DIR/servers"
STATUS_FILE="${STATUS_FILE:-$CONFIG_DIR/status.tsv}"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"

# -- pretty output -----------------------------------------------------------
if [ -t 2 ]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'
  C_B=$'\033[1;36m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { printf '%s[OK]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s!%s  %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[ERR]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
step() { printf '%s->%s %s\n' "$C_B" "$C_0" "$*" >&2; }

# -- small helpers -----------------------------------------------------------
# single-quote a value so it is safe to splice into a remote shell string
shquote() { printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"; }

# sanitize a string for use as a filename
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | tr -s '_'; }

# normalize a string for use as a domain: lowercase, squeeze dashes, trim non-domain chars
safe_domain() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-' | tr -s '-' | sed 's/^-//;s/-$//'
}

# normalize a string for use as a database name / username (alphanumeric + underscore)
safe_db_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_' | sed 's/^_//;s/_$//' | cut -c1-32
}

# convert bytes to human readable (e.g. 2147483648 -> 2.0 GiB)
human_bytes() {
  local bytes="${1:-0}" unit
  for unit in B KiB MiB GiB TiB; do
    [ "$bytes" -lt 1024 ] && { printf '%s %s' "$bytes" "$unit"; return; }
    bytes=$((bytes / 1024))
  done
  printf '%s PiB' "$bytes"
}

# generate a reasonably strong password (32 chars, shell/URL-safe)
random_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9!#%*+,-./:=?@^_|~' < /dev/urandom | head -c 32
  echo
}

# trim whitespace + CR (public alias of the internal _trim)
trim() { _trim "$1"; }

# prompt with optional default; under BATCH=1, returns the default silently
ask() { # ask "Prompt" [default]
  local prompt="$1" default="${2:-}" reply
  if [ "${BATCH:-0}" = "1" ]; then printf '%s' "$default"; return; fi
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  read -r reply || true
  printf '%s' "${reply:-$default}"
}

# yes/no prompt; under BATCH=1, returns the default (0=yes when default is y)
ask_yn() { # ask_yn "Prompt" [default y|n]  -> returns 0=yes 1=no
  local prompt="$1" default="${2:-n}" reply
  if [ "${BATCH:-0}" = "1" ]; then [ "$default" = "y" ] && return 0 || return 1; fi
  while true; do
    if [ "$default" = "y" ]; then
      printf '%s [Y/n]: ' "$prompt" >&2
    else
      printf '%s [y/N]: ' "$prompt" >&2
    fi
    read -r reply || true
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

# strip ANSI escape codes (useful when parsing colored script output)
strip_ansi() { printf '%s' "$1" | sed $'s/\x1b\[[0-9;]*m//g'; }

# -- status tracking ---------------------------------------------------------
# init_status() - create the status TSV with headers if missing.
init_status() {
  [ -f "$STATUS_FILE" ] || printf '%s\t%s\t%s\t%s\t%s\n' \
    "timestamp" "site_key" "phase" "status" "detail" > "$STATUS_FILE"
}
# update_status <site_key> <phase> <status> [detail]
# phases: discovered | backed_up | site_created | db_created | uploaded | extracted | imported | configured | deployed | verified | failed
# status: pending | running | ok | warn | fail
update_status() {
  local site_key="$1" phase="$2" status="$3" detail="${4:-}"
  init_status
  # remove any previous line for this site_key+phase, then append new state
  local tmp
  tmp="$(mktemp)"
  grep -vF "$(printf '%s\t%s\t' "$site_key" "$phase")" "$STATUS_FILE" > "$tmp" || true
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%FT%T)" "$site_key" "$phase" "$status" "$detail" >> "$tmp"
  mv "$tmp" "$STATUS_FILE"
}
# get_status <site_key> <phase> - prints the status value (or empty)
get_status() {
  [ -f "$STATUS_FILE" ] || return 0
  awk -F'\t' -v key="$1" -v phase="$2" '
    NR>1 && $2==key && $3==phase { print $4 }
  ' "$STATUS_FILE" | tail -1
}

# -- Ploi API helpers --------------------------------------------------------
# ploi_curl <method> <path> [extra curl args...]
# PLOI_API_TOKEN and PLOI_API_URL must be set.
# Exits non-zero on HTTP 4xx/5xx and prints the error body to stderr.
ploi_curl() {
  local method="$1" path="$2"; shift 2
  [ -n "${PLOI_API_TOKEN:-}" ] || die "PLOI_API_TOKEN is not set"
  [ -n "${PLOI_API_URL:-}" ] || die "PLOI_API_URL is not set"
  # path may be full URL or relative
  local url
  case "$path" in
    http*) url="$path" ;;
    *)     url="${PLOI_API_URL%/}/${path#/}" ;;
  esac
  # prefer --fail-with-body so error messages are preserved; fall back to --fail
  local fail_flag='--fail'
  curl --help | grep -q -- '--fail-with-body' && fail_flag='--fail-with-body'
  curl -sSL "$fail_flag" -X "$method" \
    -H "Authorization: Bearer ${PLOI_API_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@" "$url"
}

# ploi_ensure_server_id - if PLOI_SERVER_ID is blank, list servers and prompt.
ploi_ensure_server_id() {
  [ -n "${PLOI_SERVER_ID:-}" ] && return 0
  command -v jq >/dev/null 2>&1 || die "jq is required to list Ploi servers"
  step "PLOI_SERVER_ID not set; fetching your Ploi servers ..."
  local json
  json=$(ploi_curl GET /servers) || die "failed to list Ploi servers"
  local count
  count=$(printf '%s' "$json" | jq '.data | length')
  if [ "$count" -eq 0 ]; then
    die "no Ploi servers found for this API token"
  fi
  printf '%s\n' "Available servers:" >&2
  local i name id ip php
  for i in $(seq 0 $((count - 1))); do
    name=$(printf '%s' "$json" | jq -r ".data[$i].name // empty")
    id=$(printf '%s' "$json" | jq -r ".data[$i].id // empty")
    ip=$(printf '%s' "$json" | jq -r ".data[$i].ip_address // empty")
    php=$(printf '%s' "$json" | jq -r "[.data[$i].installed_php_versions[]?] | join(', ') // empty")
    printf '  %d) %s (id=%s, ip=%s, php: %s)\n' "$((i+1))" "$name" "$id" "$ip" "$php" >&2
  done
  local sel
  sel=$(ask 'Pick target Ploi server' "1")
  case "$sel" in
    ''|*[!0-9]*) die "invalid selection: $sel" ;;
  esac
  if ! { [ "$sel" -ge 1 ] && [ "$sel" -le "$count" ]; }; then
    die "out of range: $sel"
  fi
  PLOI_SERVER_ID=$(printf '%s' "$json" | jq -r ".data[$((sel-1))].id")
  export PLOI_SERVER_ID
  log "Selected Ploi server id=${PLOI_SERVER_ID}"
}

# ploi_remote <command-string> - run as the per-site system user.
ploi_remote() { ploi_site_remote "$1"; }

# ploi_scp <source> <dest> - scp as the per-site system user.
ploi_scp() { ploi_site_scp "$@"; }

# ploi_site_ssh_opts - populate PLOI_SITE_SSH_OPTS for the per-site system user.
ploi_site_ssh_opts() {
  PLOI_SITE_SSH_OPTS=(
    -i "${PLOI_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    -p "${PLOI_SSH_PORT:-22}"
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ConnectTimeout=15
  )
}

# ploi_site_ssh_host - print site-user@host.
ploi_site_ssh_host() {
  printf '%s@%s' "${PLOI_SITE_USER:-ploi}" "${PLOI_SSH_HOST:-}"
}

# ploi_site_remote <command-string> - run as the per-site system user.
ploi_site_remote() {
  ploi_site_ssh_opts
  # shellcheck disable=SC2029
  ssh "${PLOI_SITE_SSH_OPTS[@]}" "$(ploi_site_ssh_host)" "$1"
}

# ploi_site_scp <source> <dest> - scp as the per-site system user.
ploi_site_scp() {
  ploi_site_ssh_opts
  scp -P "${PLOI_SSH_PORT:-22}" -i "${PLOI_SSH_KEY:-$HOME/.ssh/id_ed25519}" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$@"
}

# ploi_admin_ssh_opts - populate PLOI_ADMIN_SSH_OPTS for the privileged admin user.
ploi_admin_ssh_opts() {
  PLOI_ADMIN_SSH_OPTS=(
    -i "${PLOI_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    -p "${PLOI_SSH_PORT:-22}"
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ConnectTimeout=15
  )
}

# ploi_admin_ssh_host - print admin-user@host.
ploi_admin_ssh_host() {
  printf '%s@%s' "${PLOI_SSH_USER:-ploi}" "${PLOI_SSH_HOST:-}"
}

# ploi_admin_remote <command-string> - run as the privileged admin user.
ploi_admin_remote() {
  ploi_admin_ssh_opts
  # shellcheck disable=SC2029
  ssh "${PLOI_ADMIN_SSH_OPTS[@]}" "$(ploi_admin_ssh_host)" "$1"
}

# ploi_wait - short pause after API-created resources.
ploi_wait() {
  local seconds="${PLOI_WAIT_SECONDS:-5}"
  [ "$seconds" -gt 0 ] && sleep "$seconds"
}

# ssh_public_key_for <private-key-path> - print the matching public key,
# deriving it with ssh-keygen -y if the .pub file does not exist.
ssh_public_key_for() {
  local priv="$1" pub
  [ -f "$priv" ] || die "SSH private key not found: $priv"
  pub="${priv}.pub"
  if [ -f "$pub" ]; then
    cat "$pub"
  else
    ssh-keygen -y -f "$priv" 2>/dev/null || die "could not derive public key from $priv (run: ssh-keygen -y -f $priv > $pub)"
  fi
}

# -- Ploi source helpers (Ploi -> Ploi migrations) ----------------------------
# Source server API - uses the shared PLOI_API_TOKEN / PLOI_API_URL.
ploi_source_curl() {
  local method="$1" path="$2"; shift 2
  [ -n "${PLOI_API_TOKEN:-}" ] || die "PLOI_API_TOKEN is not set"
  [ -n "${PLOI_API_URL:-}" ] || die "PLOI_API_URL is not set"
  local url
  case "$path" in
    http*) url="$path" ;;
    *)     url="${PLOI_API_URL%/}/${path#/}" ;;
  esac
  local fail_flag='--fail'
  curl --help | grep -q -- '--fail-with-body' && fail_flag='--fail-with-body'
  curl -sSL "$fail_flag" -X "$method" \
    -H "Authorization: Bearer ${PLOI_API_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@" "$url"
}

# ploi_ensure_source_server_id - prompt to pick a source server if not set.
ploi_ensure_source_server_id() {
  [ -n "${PLOI_SOURCE_SERVER_ID:-}" ] && return 0
  command -v jq >/dev/null 2>&1 || die "jq is required to list Ploi servers"
  step "PLOI_SOURCE_SERVER_ID not set; fetching your source Ploi servers ..."
  local json
  json=$(ploi_source_curl GET /servers) || die "failed to list source Ploi servers"
  local count
  count=$(printf '%s' "$json" | jq '.data | length')
  if [ "$count" -eq 0 ]; then
    die "no source Ploi servers found for this API token"
  fi
  printf '%s\n' "Available source servers:" >&2
  local i name id ip php
  for i in $(seq 0 $((count - 1))); do
    name=$(printf '%s' "$json" | jq -r ".data[$i].name // empty")
    id=$(printf '%s' "$json" | jq -r ".data[$i].id // empty")
    ip=$(printf '%s' "$json" | jq -r ".data[$i].ip_address // empty")
    php=$(printf '%s' "$json" | jq -r "[.data[$i].installed_php_versions[]?] | join(', ') // empty")
    printf '  %d) %s (id=%s, ip=%s, php: %s)\n' "$((i+1))" "$name" "$id" "$ip" "$php" >&2
  done
  local sel
  sel=$(ask 'Pick source Ploi server' "1")
  case "$sel" in
    ''|*[!0-9]*) die "invalid selection: $sel" ;;
  esac
  if ! { [ "$sel" -ge 1 ] && [ "$sel" -le "$count" ]; }; then
    die "out of range: $sel"
  fi
  PLOI_SOURCE_SERVER_ID=$(printf '%s' "$json" | jq -r ".data[$((sel-1))].id")
  export PLOI_SOURCE_SERVER_ID
  log "Selected source Ploi server id=${PLOI_SOURCE_SERVER_ID}"
}

# ploi_source_ssh_opts - populate PLOI_SOURCE_SSH_OPTS for the source admin user.
ploi_source_ssh_opts() {
  PLOI_SOURCE_SSH_OPTS=(
    -i "${PLOI_SOURCE_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    -p "${PLOI_SOURCE_SSH_PORT:-22}"
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ConnectTimeout=15
  )
}

# ploi_source_ssh_host - print source-admin-user@host.
ploi_source_ssh_host() {
  printf '%s@%s' "${PLOI_SOURCE_SSH_USER:-ploi}" "${PLOI_SOURCE_SSH_HOST:-}"
}

# ploi_source_remote <command-string> - run as the source privileged admin user.
ploi_source_remote() {
  ploi_source_ssh_opts
  # shellcheck disable=SC2029
  ssh "${PLOI_SOURCE_SSH_OPTS[@]}" "$(ploi_source_ssh_host)" "$1"
}

# ploi_source_scp <source> <dest> - scp as the source privileged admin user.
ploi_source_scp() {
  ploi_source_ssh_opts
  scp -P "${PLOI_SOURCE_SSH_PORT:-22}" -i "${PLOI_SOURCE_SSH_KEY:-$HOME/.ssh/id_ed25519}" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$@"
}
