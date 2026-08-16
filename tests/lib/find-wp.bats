#!/usr/bin/env bats
# Integration test for lib/find-wp.sh.
#
# Instead of a real sshd container (slow and environment-sensitive), this test
# mounts a fake `ssh` executable on PATH. The fake runs the commands that
# find-wp.sh sends against a local fixture filesystem, exercising the full
# orchestration and key=value output contract without network I/O.

setup() {
  FIXTURE="${BATS_TEST_DIRNAME}/../fixtures/find-wp"
  KEY_DIR="${BATS_TEST_TMPDIR}/ssh"
  mkdir -p "$KEY_DIR"
  ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -q

  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$BIN"
  ln -sf "$FIXTURE/ssh" "$BIN/ssh"

  export SSH_HOST="fakeuser@127.0.0.1"
  export SSH_PORT="22"
  export SSH_KEY="$KEY_DIR/id_ed25519"
  export DOMAIN="example.com"
  export BATCH=1
  export PATH="$BIN:$PATH"
}

@test "find-wp discovers fixture WordPress install" {
  run bash "${BATS_TEST_DIRNAME}/../../lib/find-wp.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]
  [[ "$output" == *"wp_path="* ]]
  [[ "$output" == *"siteurl=https://example.com"* ]]
  [[ "$output" == *"wp_version=6.5"* ]]
  [[ "$output" == *"db_name=example_db"* ]]
  [[ "$output" == *"db_prefix=wp_"* ]]
  [[ "$output" == *"php_version=8.2"* ]]
}

@test "find-wp reports unreachable when ssh fails" {
  rm "$BIN/ssh"
  cat > "$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
  chmod +x "$BIN/ssh"
  run bash "${BATS_TEST_DIRNAME}/../../lib/find-wp.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=unreachable"* ]]
}

@test "find-wp reports not_found when no WordPress matches" {
  rm "$BIN/ssh"
  cat > "$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${!#}"
case "$cmd" in
  'printf ok\n') echo ok ;;
  *) echo ;;
esac
EOF
  chmod +x "$BIN/ssh"
  run bash "${BATS_TEST_DIRNAME}/../../lib/find-wp.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=not_found"* ]]
}