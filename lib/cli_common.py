"""Shared helpers for the Python CLIs (backup, migrate).

Provides:
  - expand_path(value)            - expand a leading ~ to $HOME
  - load_dotenv(path)             - read KEY=VALUE lines from a .env file
  - save_dotenv(path, env)        - write env back, preserving comments/order
  - prompt(msg, default, ...)     - interactive prompt with optional default
  - confirm(msg, default=True)    - y/n prompt, returns bool
  - run(cmd, env, cwd, check)     - stream a shell command to the terminal
  - check_tools(tools, any_of, ...) - exit if required CLI tools are missing

BATCH=1 contract:
  - prompt() returns its default silently when the environment variable
    BATCH is set to "1".
  - confirm() returns its default bool silently under BATCH=1.
  This matches the shell helpers ask() / ask_yn() in lib/output.sh.

Usage from a top-level CLI:

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
    from cli_common import load_dotenv, save_dotenv, prompt, confirm, expand_path
"""

import os
import subprocess
import sys
from pathlib import Path


def expand_path(value):
    """Expand a leading ~ to $HOME. Leaves absolute and relative paths alone."""
    if value and value.startswith("~"):
        value = str(Path.home()) + value[1:]
    return value


def load_dotenv(path):
    """Read KEY=VALUE lines from a file, ignoring comments/blank lines.

    Values may be wrapped in matching " or ' quotes; both are stripped.
    A leading ~ in a value is expanded to $HOME.
    Returns a dict; missing file returns an empty dict.
    """
    env = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        val = val.strip().strip('"').strip("'")
        env[key.strip()] = expand_path(val)
    return env


def save_dotenv(path, env):
    """Write env back to .env, preserving existing comments/order when possible.

    Updates existing KEY=VALUE lines in place, appends new keys at the end
    in sorted order, and preserves every comment/blank line. Resulting file
    is chmod 600 to keep secrets local.
    """
    existing_lines = []
    if path.exists():
        for raw_line in path.read_text().splitlines():
            line = raw_line.strip()
            if line.startswith("#") or "=" not in line:
                existing_lines.append(raw_line)
                continue
            key = line.split("=", 1)[0].strip()
            if key in env:
                v = env[key]
                v = v.strip().strip('"').strip("'")
                if " " in v or "#" in v:
                    v = f'"{v}"'
                existing_lines.append(f"{key}={v}")
                del env[key]
            else:
                existing_lines.append(raw_line)

    if env:
        existing_lines.append("")
        for key, v in sorted(env.items()):
            v = v.strip().strip('"').strip("'")
            if " " in v or "#" in v:
                v = f'"{v}"'
            existing_lines.append(f"{key}={v}")

    path.write_text("\n".join(existing_lines) + "\n")
    os.chmod(path, 0o600)


def run(cmd, env=None, cwd=None, check=True):
    """Run a shell command, streaming output to the terminal."""
    print(f"\n  -> {cmd}\n")
    result = subprocess.run(cmd, shell=True, cwd=cwd, env=env)
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {result.returncode}")
    return result


def check_tools(tools, any_of=(), any_of_hint=""):
    """Exit with an error if any required CLI tool is missing.

    Every entry in `tools` must be present; for `any_of` at least one entry
    must be present (e.g. rclone/aws for R2 uploads). `any_of_hint` is extra
    guidance appended to the error when that group is missing.
    """
    missing = []
    for tool in tools:
        check = subprocess.run(["bash", "-c", f"command -v {tool}"], capture_output=True)
        if check.returncode != 0:
            missing.append(tool)
    if missing:
        print(f"[ERR] Missing required tools: {', '.join(missing)}")
        sys.exit(1)
    if any_of:
        for alt in any_of:
            check = subprocess.run(["bash", "-c", f"command -v {alt}"], capture_output=True)
            if check.returncode == 0:
                return
        msg = f"[ERR] Missing a required tool (any of: {', '.join(any_of)})."
        if any_of_hint:
            msg += f" {any_of_hint}"
        print(msg)
        sys.exit(1)


def prompt(msg, default=None, secret=False, required=False):
    """Interactive prompt with optional default. Reads from stdin.

    Under BATCH=1 this returns the default silently - the CLI dispatch
    scripts set BATCH=1 to skip prompts entirely. If required=True and
    no default is provided, an empty string is returned; callers running
    under BATCH should pre-populate the corresponding env variable.
    """
    if os.environ.get("BATCH") == "1":
        return default or ""
    display_default = "*****" if (secret and default) else default
    if default:
        raw = input(f"{msg} [{display_default}]: ").strip()
    else:
        raw = input(f"{msg}: ").strip()
    value = raw if raw else (default or "")
    while required and not value:
        value = input(f"{msg} (required): ").strip()
    return value


def confirm(msg, default=True):
    """Y/n prompt; loops until the user answers yes or no. Returns bool.

    Under BATCH=1 this returns default silently.
    """
    if os.environ.get("BATCH") == "1":
        return default
    hint = "Y/n" if default else "y/N"
    while True:
        reply = input(f"{msg} [{hint}]: ").strip().lower()
        if not reply:
            return default
        if reply in ("y", "yes"):
            return True
        if reply in ("n", "no"):
            return False