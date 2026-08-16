#!/usr/bin/env bats
# Tests for lib/output.sh - interactive prompts with injected streams.

setup() {
  # shellcheck source=../../lib/output.sh
  . "${BATS_TEST_DIRNAME}/../../lib/output.sh"
  ASK_OUT="${BATS_TEST_TMPDIR}/ask.out"
}

@test "ask returns typed reply from stdin" {
  result=$(printf 'typed\n' | ask "Enter value" "default")
  [ "$result" = "typed" ]
}

@test "ask returns default on empty stdin" {
  result=$(: | ask "Enter value" "fallback")
  [ "$result" = "fallback" ]
}

@test "ask_in accepts custom input/output fds" {
  exec 5< <(printf 'custom\n')
  exec 6>"$ASK_OUT"
  result=$(ask_in "Prompt" "default" 5 6)
  rc=$?
  exec 5<&-
  exec 6>&-
  [ "$rc" -eq 0 ]
  [ "$result" = "custom" ]
  grep -qF "Prompt [default]:" "$ASK_OUT"
}

@test "ask_yn returns 0 for yes" {
  printf 'yes\n' | ask_yn "Proceed" "n"
}

@test "ask_yn returns 1 for no" {
  ! printf 'no\n' | ask_yn "Proceed" "y"
}

@test "ask_yn loops until valid answer" {
  printf 'maybe\ny\n' | ask_yn "Proceed" "n"
}

@test "ask_yn_in accepts custom input/output fds" {
  exec 5< <(printf 'y\n')
  exec 6>"$ASK_OUT"
  ask_yn_in "Proceed" "n" 5 6
  rc=$?
  exec 5<&-
  exec 6>&-
  [ "$rc" -eq 0 ]
  grep -qF "Proceed [y/N]:" "$ASK_OUT"
}

@test "ask short-circuits in BATCH mode" {
  BATCH=1 run ask "Name" "foo"
  [ "$status" -eq 0 ]
  [ "$output" = "foo" ]
}

@test "ask_yn short-circuits in BATCH mode" {
  BATCH=1 run ask_yn "Continue" "y"
  [ "$status" -eq 0 ]
  BATCH=1 run ask_yn "Continue" "n"
  [ "$status" -eq 1 ]
}