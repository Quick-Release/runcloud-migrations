# shellcheck shell=bash
# lib/env.sh - .env loader.
#
# Defines:
#   _trim <string>              - strip whitespace + CR (private)
#   load_env <file>             - export KEY=VALUE lines from a .env-style file
#   trim <string>               - public alias of _trim
#
# Real environment variables always win over .env (so `FOO=bar ./script`
# still overrides). Values may use a leading ~ which is expanded to $HOME.
# Optional `export ` prefix and surrounding "..." or '...' quotes are
# supported. NO inline comments after values, and $VAR is NOT expanded
# inside values (use ~/ or absolute paths instead).

# -- .env loader -------------------------------------------------------------
# trim leading/trailing whitespace + CR (private)
_trim() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# load_env <file>  - set KEY=VALUE lines as exported vars; env wins; ~ expanded.
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

# trim whitespace + CR (public alias of the internal _trim)
trim() { _trim "$1"; }