#!/usr/bin/env bats
# Tests for lib/csv.sh - positional CSV normalizer.

setup() {
  # shellcheck source=../../lib/common.sh
  . "${BATS_TEST_DIRNAME}/../../lib/common.sh"
  CSV="${BATS_TEST_TMPDIR}/test.csv"
}

@test "read_batch_csv skips comments, blanks, and headers" {
  cat > "$CSV" <<'EOF'
# comment
user,ip,domain
  runcloud_user , 198.51.100.10 , example.com

  another_user , 203.0.113.5
EOF
  run read_batch_csv "$CSV" user username
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = $'runcloud_user\t198.51.100.10\texample.com' ]
  [ "${lines[1]}" = $'another_user\t203.0.113.5' ]
}

@test "read_batch_csv handles multiple known headers" {
  cat > "$CSV" <<'EOF'
system_user,domain
user,domain
example,example.com
shop,shop.example.com
EOF
  run read_batch_csv "$CSV" user system_user
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = $'example\texample.com' ]
}

@test "read_batch_csv fails clearly on missing file" {
  run read_batch_csv "${BATS_TEST_TMPDIR}/missing.csv" domain
  [ "$status" -eq 1 ]
  [[ "$output" == *"CSV not found"* ]]
}