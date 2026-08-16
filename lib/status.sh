# shellcheck shell=bash
# lib/status.sh - status.tsv tracking.
#
# Defines:
#   init_status                              - create the status TSV with headers if missing
#   update_status <key> <phase> <status> [detail]
#   get_status <key> <phase>                - prints the status value (or empty)
#
# Reads $STATUS_FILE (set by the caller; typically $CONFIG_DIR/status.tsv).
# Phases: discovered | backed_up | site_created | db_created | uploaded |
#         extracted | imported | configured | deployed | verified | failed
# Status: pending | running | ok | warn | fail

# -- status tracking ---------------------------------------------------------
# init_status() - create the status TSV with headers if missing.
init_status() {
  [ -f "$STATUS_FILE" ] || printf '%s\t%s\t%s\t%s\t%s\n' \
    "timestamp" "site_key" "phase" "status" "detail" > "$STATUS_FILE"
}

# update_status <site_key> <phase> <status> [detail]
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