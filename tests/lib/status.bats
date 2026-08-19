#!/usr/bin/env bats
# Tests for lib/status.sh - status.tsv tracking.
#
# STATUS_FILE points at a temp file per test; get_status/update_status
# contract: append-only rows keyed by (site_key, phase), newest wins.

setup() {
  # shellcheck source=../../lib/status.sh
  . "${BATS_TEST_DIRNAME}/../../lib/status.sh"
  STATUS_FILE="${BATS_TEST_TMPDIR}/status.tsv"
}

@test "init_status creates the TSV with headers" {
  init_status
  [ -f "$STATUS_FILE" ]
  [ "$(head -1 "$STATUS_FILE")" = "$(printf 'timestamp\tsite_key\tphase\tstatus\tdetail')" ]
}

@test "init_status leaves an existing file untouched" {
  init_status
  before="$(wc -l < "$STATUS_FILE")"
  init_status
  [ "$(wc -l < "$STATUS_FILE")" = "$before" ]
}

@test "update_status appends a row that get_status reads back" {
  update_status "site1" "backed_up" "ok" "zip=/tmp/x.zip"
  [ "$(get_status "site1" "backed_up")" = "ok" ]
  grep -qF "$(printf 'site1\tbacked_up\tok\tzip=/tmp/x.zip')" "$STATUS_FILE"
}

@test "update_status replaces the previous row for the same key+phase" {
  update_status "site1" "backed_up" "running"
  update_status "site1" "backed_up" "ok" "zip=a.zip"
  [ "$(grep -c "site1" "$STATUS_FILE")" = "1" ]
  [ "$(get_status "site1" "backed_up")" = "ok" ]
}

@test "different phases for one site coexist" {
  update_status "site1" "backed_up" "ok"
  update_status "site1" "site_created" "ok"
  [ "$(get_status "site1" "backed_up")" = "ok" ]
  [ "$(get_status "site1" "site_created")" = "ok" ]
}

@test "different sites with the same phase coexist" {
  update_status "site1" "backed_up" "ok"
  update_status "site2" "backed_up" "fail"
  [ "$(get_status "site1" "backed_up")" = "ok" ]
  [ "$(get_status "site2" "backed_up")" = "fail" ]
}

@test "get_status returns the newest row when duplicates exist" {
  init_status
  printf '%s\t%s\t%s\t%s\t%s\n' "2024-01-01T00:00:00" "site1" "backed_up" "running" "" >> "$STATUS_FILE"
  printf '%s\t%s\t%s\t%s\t%s\n' "2024-01-02T00:00:00" "site1" "backed_up" "ok" "" >> "$STATUS_FILE"
  [ "$(get_status "site1" "backed_up")" = "ok" ]
}

@test "get_status on a missing file returns empty with rc 0" {
  run get_status "site1" "backed_up"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
