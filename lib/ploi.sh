# shellcheck shell=bash
# lib/ploi.sh - Ploi API client + SSH adapter family.
#
# Requires: die, step, log, ask (from lib/output.sh); curl, ssh, scp on PATH.
# Reads:    PLOI_API_TOKEN, PLOI_API_URL, PLOI_SERVER_ID, PLOI_SSH_*,
#           PLOI_SITE_*, PLOI_ADMIN_*, PLOI_SOURCE_*, PLOI_WAIT_SECONDS.

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
# The API layer is shared with the target (see ploi_curl above); only the SSH
# adapter below is source-specific (different server, different keys).

# ploi_ensure_source_server_id - prompt to pick a source server if not set.
ploi_ensure_source_server_id() {
  [ -n "${PLOI_SOURCE_SERVER_ID:-}" ] && return 0
  command -v jq >/dev/null 2>&1 || die "jq is required to list Ploi servers"
  step "PLOI_SOURCE_SERVER_ID not set; fetching your source Ploi servers ..."
  local json
  json=$(ploi_curl GET /servers) || die "failed to list source Ploi servers"
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
  ssh "${PLOI_SOURCE_SSH_OPTS[@]}" "$(pli_source_ssh_host)" "$1"
}