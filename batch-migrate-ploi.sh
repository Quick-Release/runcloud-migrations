#!/usr/bin/env bash
#
# batch-migrate-ploi.sh
# ----------------------------------------------------------------------------
# Run ploi-migrate.sh for every site listed in a CSV of already-downloaded
# backup zips. Useful when the RunCloud backups were created first and the
# Ploi restore phase is done separately.
#
# CSV format (one site per line):
#   domain,zip_path
#   - lines starting with # and blank lines are ignored
#   - a header row whose first column is "domain" is auto-skipped
#   - zip_path can be absolute or relative to the project root
#
# Usage:
#   ./batch-migrate-ploi.sh                  # process all
#   ./batch-migrate-ploi.sh --csv zips.csv   # use a different CSV
#   ./batch-migrate-ploi.sh --dry-run        # show the plan only
#   ./batch-migrate-ploi.sh --limit 3        # only first N
#
# A failure on one site does NOT stop the rest.
# ----------------------------------------------------------------------------

set -uo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


RESTORE="$PROJECT_ROOT/ploi-migrate.sh"
CSV="${PLOI_CSV:-${CSV:-$PROJECT_ROOT/ploi-zips.csv}}"
LOGDIR="$LOGS_DIR"

LIMIT=0
DRY=0

usage() {
  sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --csv)     CSV="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

[ -x "$RESTORE" ] || die "restore script not found: $RESTORE"
[ -f "$CSV" ]    || die "CSV not found: $CSV (use --csv PATH)"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/batch_ploi_${TS}.log"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

printf '=== ploi batch run %s | csv=%s dry=%s limit=%s ===\n' \
  "$(date)" "$CSV" "$DRY" "${LIMIT:-all}"

n_total=0; n_ok=0; n_fail=0; n_plan=0
results=()

# CSV normalized by lib/csv.sh: comments, blank lines, and header rows removed.
while IFS=$'\t' read -r domain zip || [ -n "${domain:-}" ]; do
  [ -z "$domain" ] && continue

  if [ "$LIMIT" -gt 0 ] && [ "$n_total" -ge "$LIMIT" ]; then break; fi
  n_total=$((n_total + 1))

  # resolve zip path
  case "$zip" in
    /*) ;;
    *)  zip="$PROJECT_ROOT/$zip" ;;
  esac

  if [ "$DRY" -eq 1 ]; then
    results+=("WOULD-RUN ${domain}  ${zip}")
    n_plan=$((n_plan + 1)); continue
  fi

  [ -f "$zip" ] || { results+=("MISSING  ${domain}  ${zip}"); n_fail=$((n_fail + 1)); continue; }

  echo
  printf '%s-- %s --%s\n' "$C_B" "$domain" "$C_0"

  out=$( env DOMAIN="$domain" BATCH=1 bash "$RESTORE" "$zip" </dev/null 2>&1 )
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'

  if [ "$rc" -eq 0 ]; then
    results+=("OK       ${domain}")
    n_ok=$((n_ok + 1))
    printf '%s[OK] site done%s\n' "$C_G" "$C_0"
  else
    results+=("FAIL     ${domain}  (exit ${rc})")
    n_fail=$((n_fail + 1))
    printf '%s[ERR] site failed (exit %s) - continuing%s\n' "$C_R" "$rc" "$C_0"
  fi
done < <(read_batch_csv "$CSV" domain)

echo
echo "=== results ==="
for r in "${results[@]}"; do printf '  %s\n' "$r"; done
echo
if [ "$DRY" -eq 1 ]; then
  printf 'DRY RUN - total=%d  would-run=%d\n' "$n_total" "$n_plan"
else
  printf 'total=%d  ok=%s%d%s  fail=%s%d%s\n' \
    "$n_total" "$C_G" "$n_ok" "$C_0" "$C_R" "$n_fail" "$C_0"
fi
echo "log: $LOG"

[ "$DRY" -eq 1 ] && exit 0
[ "$n_fail" -eq 0 ]
