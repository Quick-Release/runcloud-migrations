# shellcheck shell=bash
# lib/output.sh - terminal output + interactive prompts.
#
# Defines:
#   C_G, C_Y, C_R, C_B, C_0   - ANSI color codes (empty when not a tty)
#   log  <msg...>             - green [OK] line to stderr
#   warn <msg...>             - yellow ! line to stderr
#   die  <msg...>             - red [ERR] line to stderr, exit 1
#   step <msg...>             - cyan -> line to stderr
#   ask  "Prompt" [default]   - prompt to stderr, read reply, echo to stdout
#   ask_yn "Prompt" [y|n]     - yes/no loop; returns 0=yes 1=no
#
# ask and ask_yn honour BATCH=1 by silently returning the default. Callers
# run with BATCH=1 to make prompts fully non-interactive.

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