# shellcheck shell=bash
# ============================================================================
# lib/common.sh — shared helpers + .env loader for the runcloud→ploi toolkit.
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

# ── .env loader ─────────────────────────────────────────────────────────────
# trim leading/trailing whitespace + CR
_trim() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# load_env <file>  — set KEY=VALUE lines as exported vars; env wins; ~ expanded.
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

# ── paths (overridable via .env / environment) ──────────────────────────────
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$PROJECT_ROOT/downloads}"
CONFIG_DIR="${CONFIG_DIR:-$PROJECT_ROOT/config}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"
SERVERS_DIR="$CONFIG_DIR/servers"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR"

# ── pretty output ───────────────────────────────────────────────────────────
if [ -t 2 ]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'
  C_B=$'\033[1;36m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { printf '%s✔%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s!%s  %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s✖%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
step() { printf '%s→%s %s\n' "$C_B" "$C_0" "$*" >&2; }

# ── small helpers ───────────────────────────────────────────────────────────
# single-quote a value so it is safe to splice into a remote shell string
shquote() { printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"; }

# sanitize a string for use as a filename
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

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
ask_yn() { # ask_yn "Prompt" [default y|n]  → returns 0=yes 1=no
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
