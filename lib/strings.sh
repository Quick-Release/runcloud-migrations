# shellcheck shell=bash
# lib/strings.sh - pure string helpers (no I/O, no env).
#
# Defines:
#   shquote <value>             - single-quote a value so it is safe to splice
#                                 into a remote shell string
#   safe_name <value>           - sanitize a string for use as a filename
#   safe_domain <value>         - normalize a string for use as a domain
#   safe_db_name <value>        - normalize a string for use as a db/user name
#   human_bytes <bytes>         - convert bytes to human readable (e.g. 2.0 GiB)
#   random_password             - print a 32-char shell/URL-safe password
#   strip_ansi <string>         - strip ANSI escape codes from a string

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

# strip ANSI escape codes (useful when parsing colored script output)
strip_ansi() { printf '%s' "$1" | sed $'s/\x1b\[[0-9;]*m//g'; }