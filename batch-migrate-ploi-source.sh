#!/usr/bin/env bash
#
# batch-migrate-ploi-source.sh
# ----------------------------------------------------------------------------
# Run ploi-wp-backup.sh for every site listed in clients-ploi.csv, unattended.
#
# CSV format (one site per line):
#   system_user,domain
#   - lines starting with # and blank lines are ignored
#   - a header row whose first column is "system_user" or "user" is auto-skipped
#
# Usage:
#   ./batch-migrate-ploi-source.sh                  # process all
#   ./batch-migrate-ploi-source.sh --dry-run        # show the plan only
#   ./batch-migrate-ploi-source.sh --force          # ignore resume state, redo every site
#   ./batch-migrate-ploi-source.sh --csv other.csv  # use a different CSV
#   ./batch-migrate-ploi-source.sh --limit 5        # only first N
#   ./batch-migrate-ploi-source.sh --retry-failed   # only re-run failed sites
#
# Sites run SEQUENTIALLY. A failure on one site does NOT stop the rest.
# ----------------------------------------------------------------------------

set -uo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


WORKSPACE="$PROJECT_ROOT"
BACKUP="$WORKSPACE/ploi-wp-backup.sh"
CSV="${PLOI_SOURCE_CSV:-${CSV:-$WORKSPACE/clients-ploi.csv}}"
STATE_DIR="$CONFIG_DIR"
STATE="$STATE_DIR/batch-ploi-source-done.tsv"
FAILED="$STATE_DIR/batch-ploi-source-failed.tsv"
LOGDIR="$LOGS_DIR"

FORCE=0
DRY=0
LIMIT=0
RETRY_FAILED=0

usage() {
  sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --csv)          CSV="$2"; shift 2 ;;
    --limit)        LIMIT="$2"; shift 2 ;;
    --force)        FORCE=1; shift ;;
    --dry-run)      DRY=1; shift ;;
    --retry-failed) RETRY_FAILED=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

[ -f "$BACKUP" ] || die "backup script not found: $BACKUP"
[ -f "$CSV" ]    || die "CSV not found: $CSV (use --csv PATH or create clients-ploi.csv)"

key_of() {
  printf '%s@%s/%s' "$1" "${PLOI_SOURCE_SSH_HOST:-?}" "$2"
}
done_already() {
  [ -f "$STATE" ] || return 1
  awk -F'\t' -v key="$1" 'NR>1 && $2==key { found=1 } END { exit !found }' "$STATE"
}
failed_already() {
  [ -f "$FAILED" ] || return 1
  awk -F'\t' -v key="$1" 'NR>1 && $2==key { found=1 } END { exit !found }' "$FAILED"
}
mark_done() { printf '%s\t%s\t%s\n' "$(date +%FT%T)" "$1" "${2:--}" >> "$STATE"; }
mark_failed() { printf '%s\t%s\t%s\n' "$(date +%FT%T)" "$1" "${2:--}" >> "$FAILED"; }
clear_failed() {
  [ -f "$FAILED" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v key="$1" 'NR==1 || $2!=key' "$FAILED" > "$tmp"
  mv "$tmp" "$FAILED"
}

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/batch_ploi_source_${TS}.log"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

printf '=== ploi-source batch run %s | csv=%s force=%s dry=%s limit=%s retry-failed=%s ===\n' \
  "$(date)" "$CSV" "$FORCE" "$DRY" "${LIMIT:-all}" "$RETRY_FAILED"

n_total=0; n_ok=0; n_fail=0; n_skip=0; n_bad=0; n_plan=0
results=()

# CSV normalized by lib/csv.sh: comments, blank lines, and header rows removed.
while IFS=$'\t' read -r user domain || [ -n "${user:-}" ]; do
  [ -z "$user" ] && continue

  if [ "$LIMIT" -gt 0 ] && [ "$n_total" -ge "$LIMIT" ]; then break; fi
  n_total=$((n_total + 1))

  if [ -z "$domain" ]; then
    results+=("INVALID  ${user}  (no domain)")
    n_bad=$((n_bad + 1)); continue
  fi

  key="$(key_of "$user" "$domain")"
  update_status "$key" "backed_up" "pending" ""

  if [ "$RETRY_FAILED" -eq 1 ] && ! failed_already "$key"; then
    results+=("SKIP     ${user}  ${domain}  - not in retry list")
    n_skip=$((n_skip + 1)); continue
  fi

  if [ "$FORCE" -ne 1 ] && done_already "$key"; then
    results+=("SKIP     ${user}  ${domain}  - already backed up")
    n_skip=$((n_skip + 1)); continue
  fi

  if [ "$DRY" -eq 1 ]; then
    results+=("WOULD-RUN ${user}  ${domain}")
    n_plan=$((n_plan + 1)); continue
  fi

  echo
  printf '%s-- %s / %s --%s\n' "$C_B" "$user" "$domain" "$C_0"

  child_env=( PLOI_SOURCE_SYSTEM_USER="$user" PLOI_SOURCE_DOMAIN="$domain" DOMAIN="$domain" BATCH=1 )
  clear_failed "$key"
  update_status "$key" "backed_up" "running" ""
  out=$( env "${child_env[@]}" bash "$BACKUP" </dev/null 2>&1 )
  rc=$?

  printf '%s\n' "$out" | sed 's/^/    /'

  if [ "$rc" -eq 0 ]; then
    prod=$(printf '%s\n' "$out" | grep -E 'Backup complete:' | tail -1 | sed -E 's/.*Backup complete:[[:space:]]*//')
    prod="$(strip_ansi "$prod")"
    [ -n "$prod" ] || prod="(see log)"
    mark_done "$key" "$prod"
    update_status "$key" "backed_up" "ok" "zip=$(basename "$prod")"
    results+=("OK       ${user}  ${domain}  -> $(basename "$prod")")
    n_ok=$((n_ok + 1))
    printf '%s[OK] site done%s\n' "$C_G" "$C_0"
  else
    mark_failed "$key" "exit ${rc}"
    update_status "$key" "backed_up" "fail" "exit=${rc}"
    results+=("FAIL     ${user}  ${domain}  (exit ${rc})")
    n_fail=$((n_fail + 1))
    printf '%s[ERR] site failed (exit %s) - continuing%s\n' "$C_R" "$rc" "$C_0"
  fi
done < <(read_batch_csv "$CSV" user system_user)

echo
echo "=== results ==="
if [ "${#results[@]}" -gt 0 ]; then
  for r in "${results[@]}"; do printf '  %s\n' "$r"; done
fi
echo
if [ "$DRY" -eq 1 ]; then
  printf 'DRY RUN - total=%d  would-run=%d  skip=%d  invalid=%d\n' \
    "$n_total" "$n_plan" "$n_skip" "$n_bad"
else
  printf 'total=%d  ok=%s%d%s  fail=%s%d%s  skip=%s%d%s  invalid=%d\n' \
    "$n_total" "$C_G" "$n_ok" "$C_0" "$C_R" "$n_fail" "$C_0" "$C_Y" "$n_skip" "$C_0" "$n_bad"
fi
echo "log:          $LOG"
echo "resume state: $STATE"
echo "failed state: $FAILED"

[ "$DRY" -eq 1 ] && exit 0
[ "$n_fail" -eq 0 ] && [ "$n_bad" -eq 0 ]
