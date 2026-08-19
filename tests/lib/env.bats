#!/usr/bin/env bats
# Tests for lib/env.sh - .env loader and trim helper.
#
# Each bats test runs in its own subshell, so the variables load_env
# exports cannot leak between tests.

setup() {
  # shellcheck source=../../lib/env.sh
  . "${BATS_TEST_DIRNAME}/../../lib/env.sh"
  ENV_FILE="${BATS_TEST_TMPDIR}/test.env"
}

@test "trim strips surrounding whitespace" {
  [ "$(trim '  hello  ')" = "hello" ]
}

@test "trim strips a trailing CR" {
  [ "$(trim "$(printf 'hello\r')")" = "hello" ]
}

@test "load_env sets values from a file" {
  printf 'FOO=bar\nBAZ=qux\n' > "$ENV_FILE"
  load_env "$ENV_FILE"
  [ "$FOO" = "bar" ]
  [ "$BAZ" = "qux" ]
}

@test "load_env exports values to child processes" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  load_env "$ENV_FILE"
  run bash -c 'echo "${FOO:-unset}"'
  [ "$output" = "bar" ]
}

@test "load_env skips comments, blanks and lines without =" {
  printf '# comment\n\nFOO=bar\nnovalue\n' > "$ENV_FILE"
  load_env "$ENV_FILE"
  [ "$FOO" = "bar" ]
  [ -z "${novalue+x}" ]
}

@test "load_env strips matching double quotes" {
  printf 'FOO="hello world"\n' > "$ENV_FILE"
  load_env "$ENV_FILE"
  [ "$FOO" = "hello world" ]
}

@test "load_env strips matching single quotes" {
  printf "FOO='hello world'\n" > "$ENV_FILE"
  load_env "$ENV_FILE"
  [ "$FOO" = "hello world" ]
}

@test "load_env expands a leading ~ and a bare ~ to HOME" {
  printf 'KEY=~/path\nBARE=~\n' > "$ENV_FILE"
  load_env "$ENV_FILE"
  [ "$KEY" = "$HOME/path" ]
  [ "$BARE" = "$HOME" ]
}

@test "load_env honours an export prefix" {
  printf 'export FOO=bar\n' > "$ENV_FILE"
  load_env "$ENV_FILE"
  [ "$FOO" = "bar" ]
}

@test "real environment wins over the file" {
  FOO=from_env
  printf 'FOO=from_file\n' > "$ENV_FILE"
  load_env "$ENV_FILE"
  [ "$FOO" = "from_env" ]
}

@test "load_env on a missing file is a no-op" {
  run load_env "${BATS_TEST_TMPDIR}/does-not-exist.env"
  [ "$status" -eq 0 ]
}
