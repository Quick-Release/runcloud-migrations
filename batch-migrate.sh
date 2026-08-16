#!/usr/bin/env bash
#
# batch-migrate.sh
# ----------------------------------------------------------------------------
# Run runcloud-wp-backup.sh for every site listed in clients.csv, unattended.
#
# CSV format (one site per line):
#   user,ip[,domain]
#   - lines starting with # and blank lines are ignored
#   - a header row whose first column is "user"/"username" is auto-skipped
#   - domain is OPTIONAL — auto-detected on the server if omitted
#   - CRLF (Excel/Windows) line endings are tolerated
#
# Usage:
#   ./batch-migrate.sh                  # process all, resuming from last run
#   ./batch-migrate.sh --dry-run        # show the plan; connect/run nothing
#   ./batch-migrate.sh --force          # ignore resume state, redo every site
#   ./batch-migrate.sh --csv other.csv  # use a different CSV
#   ./batch-migrate.sh --limit 5        # only process the first N sites
#   ./batch-migrate.sh --retry-failed   # only re-run sites in batch-failed.tsv
#
# Sites run SEQUENTIALLY (one backup at a time). A failure on one site does NOT
# stop the rest. Completed sites are recorded in config/batch-done.tsv and
# skipped on the next run unless --force is given. Failed sites are recorded in
# config/batch-failed.tsv and can be retried with --retry-failed.
#
# Env overrides (apply to every site): CSV, RC_USER, RC_IP, DOMAIN, SSH_PORT,
# SSH_KEY. Per-CSV-row values take precedence for RC_USER/RC_IP/DOMAIN.
# ----------------------------------------------------------------------------

set -uo pipefail            # NOTE: no -e — a single site failure must not abort the batch

# shared helpers, paths, and .env loader (auto-loads ./lib/common.sh → ./.env)
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


WORKSPACE="$PROJECT_ROOT"
BACKUP="$WORKSPACE/runcloud-wp-backup.sh"
CSV="${CLIENTS_CSV:-${CSV:-$WORKSPACE/clients.csv}}"
STATE_DIR="$CONFIG_DIR"
STATE="$STATE_DIR/batch-done.tsv"
FAILED="$STATE_DIR/batch-failed.tsv"
LOGDIR="$LOGS_DIR"

FORCE=0
DRY=0
LIMIT=0
RETRY_FAILED=0

# (colors + die + trim + update_status provided by lib/common.sh)

usage() {
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ── args ────────────────────────────────────────────────────────────────────
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
[ -f "$CSV" ]    || die "CSV not found: $CSV (use --csv PATH or create clients.csv)"

# ── helpers ─────────────────────────────────────────────────────────────────
is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
key_of() { # user ip domain → resume key
  if [ -n "$3" ]; then printf '%s@%s/%s' "$1" "$2" "$3"; else printf '%s@%s' "$1" "$2"; fi
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
clear_failed() { # remove a key from the failed list
  [ -f "$FAILED" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v key="$1" 'NR==1 || $2!=key' "$FAILED" > "$tmp"
  mv "$tmp" "$FAILED"
}
strip_ansi() { printf '%s' "$1" | sed $'s/\x1b\[[0-9;]*m//g'; }

# ── logging: mirror everything to a timestamped log ─────────────────────────
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/batch_${TS}.log"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

printf '=== batch run %s | csv=%s force=%s dry=%s limit=%s retry-failed=%s ===\n' \
  "$(date)" "$CSV" "$FORCE" "$DRY" "${LIMIT:-all}" "$RETRY_FAILED"

# ── counters ────────────────────────────────────────────────────────────────
n_total=0; n_ok=0; n_fail=0; n_skip=0; n_bad=0; n_plan=0
results=()

# ── main loop (runs in this shell; child reads /dev/null, not the CSV) ──────
while IFS=',' read -r rawuser rawip rawdomain _more || [ -n "${rawuser:-}" ]; do
  user="$(trim "$rawuser")"
  ip="$(trim "$rawip")"
  domain="$(trim "$rawdomain")"

  # blank / comment
  [ -z "$user" ] && continue
  [[ "$user" == \#* ]] && continue
  # header row
  [[ "${user,,}" == user || "${user,,}" == username ]] && continue

  # --limit
  if [ "$LIMIT" -gt 0 ] && [ "$n_total" -ge "$LIMIT" ]; then break; fi

  n_total=$((n_total + 1))

  # validate IP
  if [ -z "$ip" ] || ! is_ip "$ip"; then
    results+=("INVALID  ${user}  ${ip:-(no ip)}  — bad/missing IP")
    n_bad=$((n_bad + 1)); continue
  fi

  key="$(key_of "$user" "$ip" "$domain")"
  update_status "$key" "backed_up" "pending" ""

  # retry-failed mode: skip unless this key is in the failed list
  if [ "$RETRY_FAILED" -eq 1 ] && ! failed_already "$key"; then
    results+=("SKIP     ${user}  ${ip}  ${domain:-(auto)}  — not in retry list")
    n_skip=$((n_skip + 1)); continue
  fi

  # resume?
  if [ "$FORCE" -ne 1 ] && done_already "$key"; then
    results+=("SKIP     ${user}  ${ip}  ${domain:-(auto)}  — already backed up")
    n_skip=$((n_skip + 1)); continue
  fi

  if [ "$DRY" -eq 1 ]; then
    results+=("WOULD-RUN ${user}  ${ip}  ${domain:-(auto)}")
    n_plan=$((n_plan + 1)); continue
  fi

  # ── run one site ──────────────────────────────────────────────────────────
  echo
  printf '%s── %s @ %s  (%s) ──%s\n' "$C_B" "$user" "$ip" "${domain:-auto-detect domain}" "$C_0"

  # build env, run child fully non-interactively
  child_env=( RC_USER="$user" RC_IP="$ip" BATCH=1 )
  [ -n "$domain" ] && child_env+=( DOMAIN="$domain" )

  clear_failed "$key"
  update_status "$key" "backed_up" "running" ""
  out=$( env "${child_env[@]}" bash "$BACKUP" </dev/null 2>&1 )
  rc=$?

  # echo child output indented under the banner
  printf '%s\n' "$out" | sed 's/^/    /'

  if [ "$rc" -eq 0 ]; then
    prod=$(printf '%s\n' "$out" | grep -E 'Backup complete:' | tail -1 | sed -E 's/.*Backup complete:[[:space:]]*//')
    prod="$(strip_ansi "$prod")"
    [ -n "$prod" ] || prod="(see log)"
    mark_done "$key" "$prod"
    update_status "$key" "backed_up" "ok" "zip=$(basename "$prod")"
    results+=("OK       ${user}  ${ip}  ${domain:-(auto)}  -> $(basename "$prod")")
    n_ok=$((n_ok + 1))
    printf '%s✔ site done%s\n' "$C_G" "$C_0"
  else
    mark_failed "$key" "exit ${rc}"
    update_status "$key" "backed_up" "fail" "exit=${rc}"
    results+=("FAIL     ${user}  ${ip}  ${domain:-(auto)}  (exit ${rc})")
    n_fail=$((n_fail + 1))
    printf '%s✖ site failed (exit %s) — continuing%s\n' "$C_R" "$rc" "$C_0"
  fi
done < "$CSV"

# ── summary ─────────────────────────────────────────────────────────────────
echo
echo "=== results ==="
if [ "${#results[@]}" -gt 0 ]; then
  for r in "${results[@]}"; do printf '  %s\n' "$r"; done
fi
echo
if [ "$DRY" -eq 1 ]; then
  printf 'DRY RUN — total=%d  would-run=%d  skip=%d  invalid=%d\n' \
    "$n_total" "$n_plan" "$n_skip" "$n_bad"
else
  printf 'total=%d  ok=%s%d%s  fail=%s%d%s  skip=%s%d%s  invalid=%d\n' \
    "$n_total" "$C_G" "$n_ok" "$C_0" "$C_R" "$n_fail" "$C_0" "$C_Y" "$n_skip" "$C_0" "$n_bad"
fi
echo "log:          $LOG"
echo "resume state: $STATE"
echo "failed state: $FAILED"

# exit non-zero if anything failed or was invalid (but dry-run is always 0)
[ "$DRY" -eq 1 ] && exit 0
[ "$n_fail" -eq 0 ] && [ "$n_bad" -eq 0 ]