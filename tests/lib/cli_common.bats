#!/usr/bin/env bats
# Tests for lib/cli_common.py - shared Python helpers.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
}

@test "prompt returns default under BATCH=1" {
  run python3 - "$LIB" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
os.environ["BATCH"] = "1"
from cli_common import prompt
print(prompt("Name", "foo"))
print(prompt("Name", default="bar"))
PYEOF
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "foo" ]
  [ "${lines[1]}" = "bar" ]
}

@test "confirm returns default under BATCH=1" {
  run python3 - "$LIB" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
os.environ["BATCH"] = "1"
from cli_common import confirm
print("yes" if confirm("Continue", default=True) else "no")
print("yes" if confirm("Continue", default=False) else "no")
PYEOF
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "yes" ]
  [ "${lines[1]}" = "no" ]
}

@test "expand_path expands leading ~" {
  run python3 - "$LIB" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
from cli_common import expand_path
print(expand_path("~/.ssh/id_ed25519"))
print(expand_path("/absolute/path"))
print(expand_path("relative/path"))
PYEOF
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$HOME/.ssh/id_ed25519" ]
  [ "${lines[1]}" = "/absolute/path" ]
  [ "${lines[2]}" = "relative/path" ]
}