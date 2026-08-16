# shellcheck shell=bash
# ============================================================================
# lib/common.sh - loader for shared helpers used across the runcloud->ploi
# toolkit. Sourcing this file pulls in:
#
#   lib/env.sh      - .env loader (_trim, load_env, trim)
#   lib/output.sh   - terminal output + interactive prompts (log/warn/die/step,
#                     ask/ask_yn, ANSI colors)
#   lib/strings.sh  - pure string helpers (shquote, safe_*, human_bytes,
#                     random_password, strip_ansi)
#   lib/status.sh   - status.tsv tracking (init_status, update_status,
#                     get_status)
#   lib/ploi.sh     - Ploi API client + SSH adapter family
#
# Sourcing is pure: no filesystem side effects. Dispatch scripts must
# invoke load_env and mkdir -p explicitly after sourcing (see
# IMPROVEMENTS.md ticket T3 for the rationale and for which scripts do it).
#
# PROJECT_ROOT is set to the parent of this lib/ directory. Path defaults
# ($DOWNLOADS_DIR, $CONFIG_DIR, $LOGS_DIR, $SERVERS_DIR, $STATUS_FILE) are
# derived from it but the directories are NOT created here.
# ============================================================================

# guard against being sourced twice in the same shell
[ -n "${_PI_COMMON_LOADED:-}" ] && return 0
_PI_COMMON_LOADED=1

# project root = parent of this lib/ directory (works from any cwd)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -- paths (overridable via .env / environment) ------------------------------
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$PROJECT_ROOT/downloads}"
CONFIG_DIR="${CONFIG_DIR:-$PROJECT_ROOT/config}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"
# SERVERS_DIR is set here for callers; shellcheck sees it as unused.
# shellcheck disable=SC2034
SERVERS_DIR="$CONFIG_DIR/servers"
STATUS_FILE="${STATUS_FILE:-$CONFIG_DIR/status.tsv}"

# -- load the sub-modules ----------------------------------------------------
# shellcheck source=lib/env.sh
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# shellcheck source=lib/output.sh
. "$(dirname "${BASH_SOURCE[0]}")/output.sh"
# shellcheck source=lib/strings.sh
. "$(dirname "${BASH_SOURCE[0]}")/strings.sh"
# shellcheck source=lib/status.sh
. "$(dirname "${BASH_SOURCE[0]}")/status.sh"
# shellcheck source=lib/ploi.sh
. "$(dirname "${BASH_SOURCE[0]}")/ploi.sh"