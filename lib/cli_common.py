"""Shared helpers for the Python CLIs (backup, migrate, migrate-cli.py).

Provides:
  - expand_path(value)            - expand a leading ~ to $HOME
  - load_dotenv(path)             - read KEY=VALUE lines from a .env file
  - save_dotenv(path, env)        - write env back, preserving comments/order
  - prompt(msg, default, ...)     - interactive prompt with optional default
  - confirm(msg, default=True)    - y/n prompt, returns bool

Usage from a top-level CLI:

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
    from cli_common import load_dotenv, save_dotenv, prompt, confirm, expand_path
"""

import os
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


def prompt(msg, default=None, secret=False, required=False):
    """Interactive prompt with optional default. Reads from stdin.

    Under BATCH=1 this returns the default silently - the CLI dispatch
    scripts set BATCH=1 to skip prompts entirely.
    """
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
    """Y/n prompt; loops until the user answers yes or no. Returns bool."""
    hint = "Y/n" if default else "y/N"
    while True:
        reply = input(f"{msg} [{hint}]: ").strip().lower()
        if not reply:
            return default
        if reply in ("y", "yes"):
            return True
        if reply in ("n", "no"):
            return False