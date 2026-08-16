#!/usr/bin/env python3
"""
Interactive migration CLI for RunCloud → Ploi and Ploi → Ploi.

Walks through migrating one WordPress site end-to-end:
  source server  →  local backup  →  target Ploi server.

It prompts only for values not already set in .env or the environment, runs
bash scripts underneath, and updates .env with the values you enter.

Usage:
  ./migrate-cli.py

Requirements: python3, bash, ssh, scp, ssh-keygen, curl, jq, zip, unzip.
"""

import os
import sys
import json
import shlex
import subprocess
import re
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parent
ENV_FILE = ROOT / ".env"
ENV_EXAMPLE = ROOT / ".env.example"


def cloudflare_api(token, api_url, path):
    """Make a Cloudflare v4 API GET call. Returns (ok, json_or_text)."""
    url = api_url.rstrip("/") + "/" + path.lstrip("/")
    req = Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    try:
        with urlopen(req) as resp:
            return True, json.loads(resp.read().decode())
    except HTTPError as e:
        body = e.read().decode()
        try:
            return False, json.loads(body)
        except json.JSONDecodeError:
            return False, {"errors": [{"message": body}]}


def check_cloudflare_dns(domain, token, api_url):
    """Return a tuple (hosted: bool, editable: bool, message)."""
    ok, data = cloudflare_api(token, api_url, "zones")
    if not ok:
        errors = data.get("errors", [])
        msg = errors[0].get("message", "unknown error") if errors else "unknown error"
        return False, False, f"Cloudflare API error: {msg}"

    zones = data.get("result", [])
    if not zones:
        return False, False, "No Cloudflare zones visible to this token."

    candidates = [z for z in zones if domain == z["name"] or domain.endswith("." + z["name"])]
    if not candidates:
        zone_names = ", ".join(sorted(z["name"] for z in zones))
        return False, False, f"Domain not found in accessible Cloudflare zones. Visible zones: {zone_names}"

    zone = max(candidates, key=lambda z: len(z["name"]))
    zone_id = zone["id"]
    zone_name = zone["name"]

    ok, records = cloudflare_api(token, api_url, f"zones/{zone_id}/dns_records?name={domain}")
    if not ok:
        return True, False, f"Hosted on Cloudflare zone '{zone_name}', but cannot read DNS records (check token permissions)."

    ok, verify = cloudflare_api(token, api_url, "user/tokens/verify")
    if ok and verify.get("success"):
        perms = verify.get("result", {})
        scopes = perms.get("scopes", [])
        has_zone_read = any("zone:read" == s.lower() for s in scopes)
        has_dns_edit = any("dns:edit" == s.lower() for s in scopes)
        if has_zone_read and has_dns_edit:
            return True, True, f"Hosted on Cloudflare zone '{zone_name}'. Token has Zone:Read + DNS:Edit."
        return True, False, f"Hosted on Cloudflare zone '{zone_name}'. Token may lack DNS edit rights (scopes: {', '.join(scopes)})."

    return True, False, f"Hosted on Cloudflare zone '{zone_name}'. Read access confirmed; edit access not verified."


def load_dotenv(path):
    """Read KEY=VALUE lines from a file, ignoring comments/blank lines."""
    env = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        val = val.strip().strip('"').strip("'")
        env[key.strip()] = val
    return env


def save_dotenv(path, env):
    """Write env back to .env, preserving existing comments/order when possible."""
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
    hint = "Y/n" if default else "y/N"
    while True:
        reply = input(f"{msg} [{hint}]: ").strip().lower()
        if not reply:
            return default
        if reply in ("y", "yes"):
            return True
        if reply in ("n", "no"):
            return False


def run(cmd, env=None, cwd=None, check=True):
    """Run a shell command, streaming output to the terminal."""
    print(f"\n  → {cmd}\n")
    result = subprocess.run(cmd, shell=True, cwd=cwd, env=env)
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {result.returncode}")
    return result


def check_tools():
    needed = ["bash", "ssh", "scp", "ssh-keygen", "curl", "jq", "zip", "unzip"]
    missing = []
    for tool in needed:
        check = subprocess.run(["bash", "-c", f"command -v {tool}"], capture_output=True)
        if check.returncode != 0:
            missing.append(tool)
    if missing:
        print(f"✖ Missing required tools: {', '.join(missing)}")
        sys.exit(1)


def ploi_get_servers(token, api_url):
    url = api_url.rstrip("/") + "/servers"
    req = Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    })
    try:
        with urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            return data.get("data", [])
    except HTTPError as e:
        body = e.read().decode()
        print(f"✖ Ploi API error: {e.code} {body}")
        return []


def ploi_pick_server(token, api_url, label):
    servers = ploi_get_servers(token, api_url)
    if not servers:
        return prompt(f"Ploi {label} server ID (numeric)", required=True)
    print(f"\n  Available Ploi {label} servers:")
    for i, s in enumerate(servers, 1):
        php_versions = ", ".join(s.get("installed_php_versions") or [])
        print(f"    {i}) {s.get('name')}  id={s.get('id')}  ip={s.get('ip_address')}  php: {php_versions}")
    choice = prompt(f"Choose {label} server", "1")
    try:
        return str(servers[int(choice) - 1]["id"])
    except (ValueError, IndexError):
        print("✖ Invalid server selection")
        sys.exit(1)


def safe_name(s):
    """Match lib/common.sh safe_name(): keep A-Za-z0-9._-, squeeze underscores."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", s)
    return re.sub(r"_+", "_", cleaned).strip("_")


def discover_runcloud(rc_user, rc_ip, ssh_key):
    """Run the RunCloud discovery script and return the saved TSV path."""
    env = os.environ.copy()
    env.update({
        "RC_USER": rc_user,
        "RC_IP": rc_ip,
        "SSH_KEY": ssh_key,
        "BATCH": "1",
    })
    run(f"{ROOT}/runcloud-site-info.sh", env=env, check=False)
    return ROOT / "config" / "sites" / f"{safe_name(rc_user + '_' + rc_ip)}.tsv"


def parse_discovery_tsv(path):
    """Return list of discovered sites from a TSV file."""
    if not path.exists():
        return []
    rows = []
    lines = path.read_text().splitlines()
    if len(lines) <= 1:
        return []
    for line in lines[1:]:
        cols = line.split("\t")
        if len(cols) >= 4:
            rows.append({
                "path": cols[0],
                "domain": cols[1],
                "wp_version": cols[2],
                "php_version": cols[3],
            })
    return rows


def parse_ploi_discovery_tsv(path):
    """Return list of discovered Ploi source sites from a TSV file."""
    if not path.exists():
        return []
    rows = []
    lines = path.read_text().splitlines()
    if len(lines) <= 1:
        return []
    for line in lines[1:]:
        cols = line.split("\t")
        if len(cols) >= 5:
            rows.append({
                "domain": cols[0],
                "system_user": cols[1],
                "path": cols[2],
                "wp_version": cols[3],
                "php_version": cols[4],
            })
    return rows


def find_latest_zip(domain=None):
    downloads = ROOT / "downloads"
    if not downloads.exists():
        return None
    if domain:
        candidates = sorted(downloads.glob(f"{domain}*.zip"))
    else:
        candidates = sorted(downloads.glob("*.zip"))
    return candidates[-1] if candidates else None


def run_dns_check(domain, cf_token, cf_url):
    if not cf_token or not domain:
        return True, "skipped"
    hosted, editable, msg = check_cloudflare_dns(domain, cf_token, cf_url)
    print(f"  {'✔' if hosted else '✖'} Cloudflare: {msg}")
    if hosted and editable:
        print("  → DNS is managed on Cloudflare and the token can edit records.")
    elif hosted:
        print("  ⚠ DNS is on Cloudflare but edit rights could not be confirmed.")
    else:
        print("  → Domain not on Cloudflare (or token has no access). Update DNS manually.")
    if not hosted or not editable:
        if not confirm("Continue migration anyway?", default=False):
            print("  Aborted. Fix DNS access and rerun.")
            sys.exit(1)
    return True, msg


def configure_target(env, env_updates, default_ssh_key):
    print("\n--- Target Ploi server ---")
    target_token = env_updates.get("PLOI_API_TOKEN") or prompt("Ploi API token", env.get("PLOI_API_TOKEN"), secret=True, required=True)
    target_url = env_updates.get("PLOI_API_URL") or prompt("Ploi API URL", env.get("PLOI_API_URL") or "https://ploi.io/api", required=True)
    env_updates.update({"PLOI_API_TOKEN": target_token, "PLOI_API_URL": target_url})

    target_server_id = env.get("PLOI_SERVER_ID", "").strip()
    if not target_server_id:
        target_server_id = ploi_pick_server(target_token, target_url, "target")
    env_updates["PLOI_SERVER_ID"] = target_server_id

    target_ssh_host = prompt("Ploi target SSH host/IP", env.get("PLOI_SSH_HOST"), required=True)
    target_ssh_user = prompt("Ploi target admin SSH username", env.get("PLOI_SSH_USER") or "ploi", required=True)
    target_ssh_key = prompt("Ploi target SSH private key", env.get("PLOI_SSH_KEY") or default_ssh_key, required=True)
    target_php = prompt("PHP version for new Ploi site", env.get("PLOI_PHP_VERSION") or "8.2", required=True)

    env_updates.update({
        "PLOI_SSH_HOST": target_ssh_host,
        "PLOI_SSH_USER": target_ssh_user,
        "PLOI_SSH_KEY": target_ssh_key,
        "PLOI_PHP_VERSION": target_php,
    })

    return target_token, target_url, target_server_id, target_ssh_host, target_ssh_user, target_ssh_key, target_php


def run_runcloud_backup(rc_user, rc_ip, ssh_key, domain):
    backup_env = os.environ.copy()
    backup_env.update({
        "RC_USER": rc_user,
        "RC_IP": rc_ip,
        "SSH_KEY": ssh_key,
        "BATCH": "1",
    })
    if domain:
        backup_env["DOMAIN"] = domain
    run(f"{ROOT}/runcloud-wp-backup.sh", env=backup_env)


def run_ploi_backup(system_user, domain):
    backup_env = os.environ.copy()
    backup_env.update({
        "PLOI_SOURCE_SYSTEM_USER": system_user,
        "PLOI_SOURCE_DOMAIN": domain,
        "DOMAIN": domain,
        "BATCH": "1",
    })
    run(f"{ROOT}/ploi-wp-backup.sh", env=backup_env)


def run_ploi_restore(domain, zip_file, target_env):
    restore_env = os.environ.copy()
    restore_env.update({
        "DOMAIN": domain or "",
        "BATCH": "1",
    })
    restore_env.update(target_env)
    run(f"{ROOT}/ploi-migrate.sh {shlex.quote(str(zip_file))}", env=restore_env)


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    print("=" * 55)
    print("  Migration CLI  —  RunCloud → Ploi  |  Ploi → Ploi")
    print("=" * 55)

    check_tools()

    if not ENV_FILE.exists() and ENV_EXAMPLE.exists():
        if confirm(".env not found. Create it from .env.example?", default=True):
            ENV_FILE.write_text(ENV_EXAMPLE.read_text())
            print(f"  ✔ Created {ENV_FILE}")

    env = load_dotenv(ENV_FILE)
    env_updates = {}

    # ── Source type ─────────────────────────────────────────────────────────
    print("\n--- Choose source type ---")
    source_type = prompt("Source type (runcloud / ploi)", env.get("MIGRATION_SOURCE_TYPE") or "runcloud", required=True).lower()
    if source_type not in ("runcloud", "ploi"):
        print("✖ Source type must be 'runcloud' or 'ploi'")
        sys.exit(1)
    env_updates["MIGRATION_SOURCE_TYPE"] = source_type

    domain = ""

    if source_type == "runcloud":
        # ── RunCloud source ─────────────────────────────────────────────────
        print("\n--- Step 1/5: RunCloud source server ---")
        rc_user = prompt("RunCloud SSH username", env.get("RC_USER"), required=True)
        rc_ip = prompt("RunCloud server IP", env.get("RC_IP"), required=True)
        domain = prompt("Domain (optional; press Enter to auto-detect)", env.get("DOMAIN"))
        ssh_key_default = env.get("SSH_KEY") or str(Path.home() / ".ssh/id_ed25519")
        ssh_key = prompt("SSH private key path", ssh_key_default, required=True)

        env_updates.update({
            "RC_USER": rc_user,
            "RC_IP": rc_ip,
            "SSH_KEY": ssh_key,
        })
        if domain:
            env_updates["DOMAIN"] = domain

        # Discovery
        print("\n--- Step 2/5: WordPress discovery ---")
        if confirm("Discover WordPress installs on the RunCloud server?", default=True):
            discover_runcloud(rc_user, rc_ip, ssh_key)
            tsv = ROOT / "config" / "sites" / f"{safe_name(rc_user + '_' + rc_ip)}.tsv"
            sites = parse_discovery_tsv(tsv)
            if sites:
                print("\n  Discovered sites:")
                for i, site in enumerate(sites, 1):
                    print(f"    {i}) {site['domain']}  WP {site['wp_version']}  PHP {site['php_version']}  {site['path']}")
                choice = prompt("Use which site? (number, or press Enter to keep current domain)", "1")
                try:
                    idx = int(choice) - 1
                    if 0 <= idx < len(sites):
                        picked = sites[idx]
                        domain = picked["domain"]
                        env_updates["DOMAIN"] = domain
                        print(f"\n  → Selected: {domain} (WP {picked['wp_version']}, PHP {picked['php_version']})")
                except ValueError:
                    pass
            else:
                print("  ! No discovery results found; continuing with provided/empty domain.")

    else:
        # ── Ploi source ───────────────────────────────────────────────────────
        print("\n--- Step 1/5: Ploi source server ---")
        source_token = prompt("Ploi API token", env.get("PLOI_API_TOKEN"), secret=True, required=True)
        source_url = prompt("Ploi API URL", env.get("PLOI_API_URL") or "https://ploi.io/api", required=True)
        env_updates.update({"PLOI_API_TOKEN": source_token, "PLOI_API_URL": source_url})

        source_server_id = env.get("PLOI_SOURCE_SERVER_ID", "").strip()
        if not source_server_id:
            source_server_id = ploi_pick_server(source_token, source_url, "source")
        env_updates["PLOI_SOURCE_SERVER_ID"] = source_server_id

        source_ssh_host = prompt("Ploi source SSH host/IP", env.get("PLOI_SOURCE_SSH_HOST"), required=True)
        source_ssh_user = prompt("Ploi source admin SSH username", env.get("PLOI_SOURCE_SSH_USER") or "ploi", required=True)
        source_ssh_key_default = env.get("PLOI_SOURCE_SSH_KEY") or env.get("SSH_KEY") or str(Path.home() / ".ssh/id_ed25519")
        source_ssh_key = prompt("Ploi source SSH private key", source_ssh_key_default, required=True)
        env_updates.update({
            "PLOI_SOURCE_SSH_HOST": source_ssh_host,
            "PLOI_SOURCE_SSH_USER": source_ssh_user,
            "PLOI_SOURCE_SSH_KEY": source_ssh_key,
        })

        print("\n--- Step 2/5: Discover WordPress sites on source Ploi server ---")
        discovery_env = os.environ.copy()
        discovery_env.update({
            "PLOI_API_TOKEN": source_token,
            "PLOI_API_URL": source_url,
            "PLOI_SOURCE_SERVER_ID": source_server_id,
            "PLOI_SOURCE_SSH_HOST": source_ssh_host,
            "PLOI_SOURCE_SSH_USER": source_ssh_user,
            "PLOI_SOURCE_SSH_KEY": source_ssh_key,
            "BATCH": "1",
        })
        run(f"{ROOT}/ploi-site-info.sh", env=discovery_env, check=False)
        tsv = ROOT / "config" / "sites" / f"ploi-{source_server_id}.tsv"
        sites = parse_ploi_discovery_tsv(tsv)

        system_user = ""
        if sites:
            print("\n  Discovered sites:")
            for i, site in enumerate(sites, 1):
                print(f"    {i}) {site['domain']}  user={site['system_user']}  WP {site['wp_version']}  PHP {site['php_version']}")
            choice = prompt("Use which site? (number)", "1")
            try:
                idx = int(choice) - 1
                if 0 <= idx < len(sites):
                    picked = sites[idx]
                    system_user = picked["system_user"]
                    domain = picked["domain"]
                    print(f"\n  → Selected: {domain} (user={system_user})")
            except ValueError:
                pass

        if not system_user or not domain:
            system_user = prompt("Source Ploi system user", required=True)
            domain = prompt("Domain to migrate", required=True)

    # ── DNS check ─────────────────────────────────────────────────────────────
    print("\n--- Step 3/5: DNS hosting check ---")
    cf_token = prompt("Cloudflare API token (optional; for DNS check)", env.get("CLOUDFLARE_API_TOKEN"), secret=True)
    if cf_token:
        cf_url = prompt("Cloudflare API URL", env.get("CLOUDFLARE_API_URL") or "https://api.cloudflare.com/client/v4", required=True)
        env_updates.update({"CLOUDFLARE_API_TOKEN": cf_token, "CLOUDFLARE_API_URL": cf_url})
        run_dns_check(domain, cf_token, cf_url)
    else:
        print("  ! No Cloudflare token provided. DNS hosting check skipped.")

    # ── Target Ploi ───────────────────────────────────────────────────────────
    default_ssh_key = env.get("SSH_KEY") or str(Path.home() / ".ssh/id_ed25519")
    if source_type == "ploi":
        default_ssh_key = env_updates.get("PLOI_SOURCE_SSH_KEY") or default_ssh_key
    target_token, target_url, target_server_id, target_ssh_host, target_ssh_user, target_ssh_key, target_php = configure_target(env, env_updates, default_ssh_key)

    # Persist everything to .env
    env.update(env_updates)
    save_dotenv(ENV_FILE, env)
    print(f"\n  ✔ Saved settings to {ENV_FILE}")

    # ── Migrate ───────────────────────────────────────────────────────────────
    print("\n--- Step 5/5: Migrate ---")
    if not confirm("Run backup from source?", default=True):
        print("  Aborted. You can rerun the CLI later; your answers are saved in .env.")
        return

    if source_type == "runcloud":
        try:
            run_runcloud_backup(rc_user, rc_ip, ssh_key, domain)
        except RuntimeError:
            print("\n✖ Backup failed. Fix the issue and rerun the CLI.")
            sys.exit(1)
    else:
        try:
            run_ploi_backup(system_user, domain)
        except RuntimeError:
            print("\n✖ Backup failed. Fix the issue and rerun the CLI.")
            sys.exit(1)

    zip_file = find_latest_zip(domain)
    if not zip_file:
        print("\n✖ Backup script succeeded but no zip was found in ./downloads")
        sys.exit(1)
    print(f"\n  ✔ Backup zip: {zip_file}")

    if not confirm("Restore this backup to the target Ploi server?", default=True):
        print(f"\n  Backup is ready: {zip_file}")
        print("  Run this later to restore:")
        print(f"    DOMAIN={shlex.quote(domain)} ./ploi-migrate.sh {shlex.quote(str(zip_file))}")
        return

    target_env = {
        "PLOI_API_TOKEN": target_token,
        "PLOI_API_URL": target_url,
        "PLOI_SERVER_ID": target_server_id,
        "PLOI_SSH_HOST": target_ssh_host,
        "PLOI_SSH_USER": target_ssh_user,
        "PLOI_SSH_KEY": target_ssh_key,
        "PLOI_PHP_VERSION": target_php,
    }
    try:
        run_ploi_restore(domain, zip_file, target_env)
    except RuntimeError:
        print("\n✖ Ploi restore failed. Check the output above and retry.")
        sys.exit(1)

    print("\n" + "=" * 55)
    print("  ✔ Migration complete")
    print("=" * 55)
    print(f"  Site:    https://{domain}")
    print(f"  Backup:  {zip_file}")
    print(f"  Status:  config/status.tsv")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n  Aborted.")
        sys.exit(1)
