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

@test "run streams the command and returns the result" {
  run python3 - "$LIB" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cli_common import run
result = run("exit 7", check=False)
print(result.returncode)
PYEOF
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "7" ]
}

@test "run raises RuntimeError when check=True and the command fails" {
  run python3 - "$LIB" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cli_common import run
try:
    run("exit 9")
except RuntimeError as e:
    print(f"caught: {e}")
PYEOF
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "caught: Command failed with exit code 9"* ]]
}

@test "check_tools passes when all tools are present" {
  run python3 - "$LIB" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cli_common import check_tools
check_tools(["bash", "sh"])
print("all present")
PYEOF
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "all present" ]
}

@test "check_tools exits 1 listing missing tools" {
  run python3 - "$LIB" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cli_common import check_tools
check_tools(["bash", "definitely-not-a-real-tool-xyz"])
PYEOF
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required tools: definitely-not-a-real-tool-xyz"* ]]
}

@test "check_tools any_of passes when one alternative exists" {
  run python3 - "$LIB" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cli_common import check_tools
check_tools(["bash"], any_of=["definitely-not-a-real-tool-xyz", "sh"])
print("group satisfied")
PYEOF
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "group satisfied" ]
}

@test "check_tools any_of exits 1 with hint when the group is missing" {
  run python3 - "$LIB" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cli_common import check_tools
check_tools(["bash"], any_of=["nope-one", "nope-two"], any_of_hint="Install something.")
PYEOF
  [ "$status" -eq 1 ]
  [[ "$output" == *"any of: nope-one, nope-two"* ]]
  [[ "$output" == *"Install something."* ]]
}