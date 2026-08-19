#!/usr/bin/env bats
# Tests for lib/backup-core.sh - the shared backup tail helpers.

setup() {
  # shellcheck source=../../lib/common.sh
  . "${BATS_TEST_DIRNAME}/../../lib/common.sh"
  STATUS_FILE="${BATS_TEST_TMPDIR}/status.tsv"
  unset RC_VERIFY_ZIP RC_CLEANUP_REMOTE_ZIP RC_CLEANUP_DB_DUMP || true
}

fake_remote()   { printf 'CMD:%s\n' "$1"; }
failed_remote() { return 1; }

@test "verify_backup_zip accepts a valid archive" {
  echo hello > "${BATS_TEST_TMPDIR}/payload.txt"
  ( cd "$BATS_TEST_TMPDIR" && zip -r -q good.zip payload.txt )
  run verify_backup_zip "${BATS_TEST_TMPDIR}/good.zip"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Archive verified"* ]]
}

@test "verify_backup_zip dies on a corrupt archive" {
  printf 'not a zip\n' > "${BATS_TEST_TMPDIR}/bad.zip"
  run verify_backup_zip "${BATS_TEST_TMPDIR}/bad.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *"corrupt"*"${BATS_TEST_TMPDIR}/bad.zip"* ]]
}

@test "verify_backup_zip skips when RC_VERIFY_ZIP=no" {
  printf 'not a zip\n' > "${BATS_TEST_TMPDIR}/bad.zip"
  RC_VERIFY_ZIP=no run verify_backup_zip "${BATS_TEST_TMPDIR}/bad.zip"
  [ "$status" -eq 0 ]
}

@test "cleanup_backup_remote_dir removes the dir via the given runner" {
  run cleanup_backup_remote_dir fake_remote "/tmp/.bak.XYZ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rm -rf '/tmp/.bak.XYZ'"* ]]
}

@test "cleanup_backup_remote_dir warns but survives runner failure" {
  run cleanup_backup_remote_dir failed_remote "/tmp/.bak.XYZ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not remove remote temp dir"* ]]
}

@test "cleanup_backup_remote_dir warns where the dir was left when disabled" {
  RC_CLEANUP_REMOTE_ZIP=no run cleanup_backup_remote_dir fake_remote "/tmp/.bak.XYZ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"left remote temp dir: /tmp/.bak.XYZ"* ]]
}

@test "cleanup_backup_db_dump removes the dump via the given runner" {
  run cleanup_backup_db_dump fake_remote "/srv/wp" "db.sql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rm -f '/srv/wp/db.sql'"* ]]
}

@test "cleanup_backup_db_dump skips when RC_CLEANUP_DB_DUMP=no" {
  RC_CLEANUP_DB_DUMP=no run cleanup_backup_db_dump fake_remote "/srv/wp" "db.sql"
  [ "$status" -eq 0 ]
  [[ "$output" != *"rm -f"* ]]
}

@test "finish_backup records ok status and prints the zip path" {
  run finish_backup "rc_user@198.51.100.10/example.com" "/tmp/downloads/example.com_.zip"
  [ "$status" -eq 0 ]
  [ "$(get_status "rc_user@198.51.100.10/example.com" "backed_up")" = "ok" ]
  [[ "$output" == *"Backup complete: /tmp/downloads/example.com_.zip"* ]]
}
