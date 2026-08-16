# runcloud-migrations

A Bash toolkit for migrating WordPress sites **off RunCloud** and **onto Ploi**, or **from one Ploi server to another Ploi server**.

```
RunCloud server  ──backup──▶  ./downloads/<domain>_<ts>.zip  ──restore──▶  Ploi server
Ploi server      ──backup──▶  ./downloads/<domain>_<ts>.zip  ──restore──▶  Ploi server
```

## What's here

| File | Purpose |
|------|---------|
| `backup` | **Unified backup CLI.** `backup runcloud` prompts for a RunCloud server + app, backs up all files (and the DB if it's WordPress), uploads a `.zip` to Cloudflare R2, and writes a markdown report with download links. `backup test` checks R2 read/write credentials. |
| `lib/backup-runcloud.sh` | Bash worker for `backup runcloud`: SSH into the server, find the app, dump the DB, zip, download, upload to R2. |
| `lib/r2-upload.sh` | Uploads a local file to Cloudflare R2 and returns a presigned or public URL (uses rclone or AWS CLI). |
| `migrate` | **Unified migration CLI.** `migrate domain.tld` discovers the source server and migrates to Ploi. `migrate setup` interactively fills in `.env`. |
| `runcloud-wp-backup.sh` | Connects to a RunCloud server over SSH, finds the WordPress install, exports the DB, zips the site, and downloads it as `<domain>_<timestamp>.zip`. |
| `runcloud-site-info.sh` | Discovers all WordPress installs on a RunCloud server and prints path, domain, WP version, PHP version, DB prefix and rough sizes. Use this to pick the right Ploi server (modern vs legacy PHP). |
| `ploi-wp-backup.sh` | Backs up one site from an existing **Ploi** server to a local zip, using a privileged admin SSH user and reading `wp-config.php` for DB credentials. |
| `ploi-site-info.sh` | Discovers WordPress sites on a source Ploi server via the Ploi API + SSH. Use this to pick the right target Ploi server. |
| `ssh-wp-backup.sh` | Backs up a WordPress site from any SSH-reachable server (DigitalOcean droplet, Coolify host bind-mount, generic VPS) by finding the install via siteurl and using wp-cli. |
| `coolify-remove.sh` | **Manual helper** to stop and remove a Coolify service from the source server after migration. Never invoked automatically. |
| `lib/find-wp.sh` | SSH probe used by `migrate` to locate a WordPress install matching a domain on any SSH server. |
| `batch-migrate.sh` | Backs up every site in `clients.csv` (RunCloud sources) unattended, with resume, retry-failed, per-site logging and status tracking. |
| `batch-migrate-ploi-source.sh` | Backs up every site in `clients-ploi.csv` (Ploi sources) unattended. |
| `ploi-migrate.sh` | Restores a downloaded backup onto a Ploi server end-to-end: create site + DB, upload zip, extract, import SQL, update `wp-config.php`, fix ownership, SSL, deploy and smoke-test. |
| `batch-migrate-ploi.sh` | Runs `ploi-migrate.sh` for every `domain,zip_path` row in a CSV. |
| `migrate.sh` | End-to-end for a single RunCloud → Ploi site: backup + restore. |
| `ploi-to-ploi.sh` | End-to-end for a single Ploi → Ploi site: backup + restore. |
| `migrate-cli.py` | Legacy interactive CLI for a single end-to-end migration (kept for backward compatibility). |
| `lib/common.sh` | Shared helpers, `.env` loader, status tracking and Ploi API/SSH helpers. |
| `.env.example` | Template for configuration. |
| `source-servers.csv.example` | Template for the source-server inventory used by `migrate`. |
| `clients.csv.example` | Template for the RunCloud backup CSV. |
| `clients-ploi.csv.example` | Template for the Ploi source backup CSV. |
| `ploi-zips.csv.example` | Template for the Ploi-only restore CSV. |

## Recommended workflow

The easiest way to migrate a single site is the unified CLI:

```bash
migrate example.com
```

It will:

1. Read your source-server inventory (`config/source-servers.csv`).
2. Probe every configured server (RunCloud, Ploi, Coolify, DigitalOcean/SSH) for a WordPress install matching `example.com`.
3. Let you choose if more than one source matches.
4. Ask for / list the target Ploi server.
5. Run the source backup.
6. Run the Ploi restore.
7. **Leave the source site untouched.** Delete it yourself after a visual check; for Coolify there is a manual `coolify-remove.sh` helper.

You can also run `migrate setup` to walk through every `.env` credential once
and save it for later commands.

Set up the inventory once:

```bash
cp source-servers.csv.example config/source-servers.csv
# edit config/source-servers.csv with each source server
```

For scripted / batch use, the individual bash scripts are still available.

## Ploi → Ploi workflow

1. **Inventory** the source Ploi server to decide the target Ploi server:
   ```bash
   ./ploi-site-info.sh
   ```
2. **Configure** `.env` with source + target Ploi API/SSH credentials.
3. **Migrate one site end-to-end** as a sanity check:
   ```bash
   ./ploi-to-ploi.sh example example.com
   ```
4. **Back up the rest** when you are ready:
   ```bash
   ./batch-migrate-ploi-source.sh --dry-run
   ./batch-migrate-ploi-source.sh
   # if anything fails: ./batch-migrate-ploi-source.sh --retry-failed
   ```
5. **Restore to target Ploi** from the generated zips:
   ```bash
   ./batch-migrate-ploi.sh --dry-run
   ./batch-migrate-ploi.sh
   ```

## RunCloud → Ploi workflow

The original workflow still works:

1. **Inventory** each RunCloud server to decide the target Ploi server:
   ```bash
   ./runcloud-site-info.sh
   ```
2. **Configure** `.env` with SSH/API credentials and default Ploi settings.
   Add `CLOUDFLARE_API_TOKEN` if you want the CLI to verify DNS access automatically.
3. **Migrate one site end-to-end** as a sanity check:
   ```bash
   ./migrate.sh runcloud_user 198.51.100.10 example.com
   ```
4. **Back up the rest** when you are ready:
   ```bash
   ./batch-migrate.sh --dry-run
   ./batch-migrate.sh
   # if anything fails: ./batch-migrate.sh --retry-failed
   ```
5. **Restore to Ploi** from the generated zips:
   ```bash
   ./batch-migrate-ploi.sh --dry-run
   ./batch-migrate-ploi.sh
   ```

> For a single site you can also run `runcloud-wp-backup.sh` and `ploi-migrate.sh`
> manually, one after the other.

> For Ploi → Ploi, run `ploi-wp-backup.sh` and `ploi-migrate.sh` manually,
> or use `ploi-to-ploi.sh` for the full flow.

## Source sites are never deleted

None of the scripts delete or disable the original website. They only read
from the source and create a local backup in `./downloads/` or `./backups/`.
You decide when to remove the old site after visually verifying the migrated
or downloaded backup.

For Coolify sources, `coolify-remove.sh` is provided as a standalone manual
helper. It is **never** invoked automatically; run it only when you are ready.

## Quick start

```bash
cp .env.example .env          # fill in target Ploi + R2 credentials
cp source-servers.csv.example config/source-servers.csv
# edit config/source-servers.csv with all your source servers

# Configure all credentials interactively:
migrate setup

# Back up one RunCloud app to R2:
backup runcloud

# Test R2 credentials:
backup test

# Migrate one site end-to-end (discovers source, asks for target):
migrate example.com

# Or run the underlying scripts manually:
./runcloud-wp-backup.sh                 # back up one RunCloud site
./ploi-migrate.sh downloads/example.com_*.zip   # restore to Ploi

# For Ploi → Ploi:
./ploi-wp-backup.sh example example.com # back up one Ploi site
./ploi-migrate.sh downloads/example.com_*.zip   # restore to another Ploi server
```

Backups land in `./downloads/` (migration) or `./backups/` + Cloudflare R2 (`backup runcloud`).

## Backup workflow

For a RunCloud site that you want to archive or hand to a client as a downloadable backup:

```bash
backup runcloud
```

It will ask for:

- RunCloud server IP / hostname
- RunCloud SSH username
- RunCloud app name
- Client email (optional)
- SSH key and port
- R2 bucket, account ID, access key, secret key
- Optional R2 public domain

What it does:

1. SSH into the RunCloud server.
2. Find the app directory (`/home/<user>/webapps/<app>` or similar).
3. Detect WordPress by looking for `wp-config.php`.
4. If WordPress, read `wp-config.php` and dump the database via `mysqldump` or `wp db export`.
5. Zip all files plus the DB dump.
6. Download the zip locally to `./backups/`.
7. Upload to Cloudflare R2 (`runcloud/<app>/<app>_<timestamp>.zip`).
8. Generate a markdown report in `./reports/` with:
   - Backup metadata
   - R2 download link
   - Ready-to-send email body
9. Optionally send the email to the client via Cloudflare Email Service.

The download link is a **presigned R2 URL valid for 30 days** (configurable with
`R2_URL_TTL_SECONDS`). If you set `R2_PUBLIC_DOMAIN` and the bucket is public,
it returns a direct public URL instead.

## Configuration (`.env` + `config/source-servers.csv`)

`migrate` and every bash script auto-load `.env` from the project root. **Real
environment variables always win** over `.env**, so `FOO=bar ./script` overrides
the file. See [`.env.example`](.env.example) for the full list and defaults.

Source servers for the unified `migrate` command are stored in
`config/source-servers.csv` (copy `source-servers.csv.example`). This file
contains secrets and is git-ignored.

### Source server inventory

`config/source-servers.csv` lists every server that might host a WordPress
site you want to migrate. Each row looks like:

```csv
name,type,ssh_host,ssh_port,ssh_user,ssh_key,api_token,api_url,server_id,web_directory,notes
runcloud-prod,runcloud,203.0.113.10,22,runcloud-user,~/.ssh/id_ed25519,,,,,
ploi-old,ploi,203.0.113.20,22,ploi,~/.ssh/id_ed25519,TOKEN,https://ploi.io/api,12345,/public,
coolify-prod,coolify,203.0.113.30,22,root,~/.ssh/id_ed25519,,,,,
do-legacy,ssh,203.0.113.40,22,root,~/.ssh/id_ed25519,,,,,
```

- `type` can be `runcloud`, `ploi`, `coolify` or `ssh`.
- `ssh` is the generic catch-all for any SSH-reachable server, including a
  DigitalOcean droplet where WordPress files are directly on disk.
- For `ploi`, `api_token`, `api_url` and `server_id` are used to look up sites
  via the Ploi API (fastest). If `server_id` is left blank, all servers visible
  to the token are searched.
- For `coolify`, the WordPress files must be bind-mounted on the host under
  `/data/coolify/services/<uuid>/...` (or another path the SSH user can read).
  After a successful migration, use the standalone `coolify-remove.sh` script
  manually when you are ready to delete the Coolify service. `migrate` will not
  delete anything on the source server.

Key groups:

- **Backup** — `R2_BUCKET`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_PUBLIC_DOMAIN`, `R2_URL_TTL_SECONDS`, `EMAIL_FROM`, `EMAIL_FROM_NAME`, `BACKUP_CLIENT_EMAIL`
- **Unified migration** — `SOURCE_SERVERS_CSV`
- **RunCloud backup** — `SSH_KEY`, `SSH_PORT`, `CLIENTS_CSV`
- **Ploi source** — `PLOI_SOURCE_SERVER_ID`, `PLOI_SOURCE_SSH_HOST/PORT/USER/KEY`, `PLOI_SOURCE_WEB_DIRECTORY` (uses the shared `PLOI_API_TOKEN`/`PLOI_API_URL`)
- **Ploi API (target)** — `PLOI_API_TOKEN`, `PLOI_API_URL`, `PLOI_SERVER_ID`
- **Ploi privileged admin (target)** — `PLOI_SSH_HOST`, `PLOI_SSH_PORT`, `PLOI_SSH_USER` (ploi/root), `PLOI_SSH_KEY`. Used only to create isolated system users and configure chroot.
- **Ploi per-site isolation** — `PLOI_SYSTEM_USER_STRATEGY=per-site`, `PLOI_ADD_SSH_KEY_TO_SITE_USER=yes`, `PLOI_CHROOT_SITE_USER=yes`
- **Ploi migration behavior** — PHP version, SSL mode, DB auto-generation
- **Cloudflare** — `CLOUDFLARE_API_TOKEN` (needs Zone:Read + DNS:Edit for DNS checks; add Email Send to send backup emails), `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_URL`
- **Safety** — `RC_MIN_FREE_BYTES`, `RC_CLEANUP_DB_DUMP`, `RC_VERIFY_ZIP`

## Per-site user isolation

By default `ploi-migrate.sh` creates a dedicated system user for each site:

1. The privileged `PLOI_SSH_USER` (ploi/root) creates the per-site user via the Ploi API.
2. The migration SSH public key is added to that user's `~/.ssh/authorized_keys`.
3. All file upload/extract/import operations run as that user — **not** as the admin.
4. If `PLOI_CHROOT_SITE_USER=yes`, the script attempts to add an sshd `Match User`
   block so the user is locked to their home directory with `internal-sftp`.

The per-site user has **no sudo access** and cannot see other sites' home directories.

## Status tracking

`config/status.tsv` records the phase and result of every migration attempt:

```
timestamp        site_key              phase       status  detail
2024-01-15T14:30:01  runcloud_user@198.51.100.10/example.com  backed_up   ok      zip=example.com_20240115-143000.zip
2024-01-15T14:35:12  ploi:example.com                           site_created ok     site_id=12345
```

Phases include `discovered`, `backed_up`, `site_created`, `db_created`, `uploaded`,
`extracted`, `imported`, `configured`, `deployed`, `verified` and `failed`.

## Resume and retry

- `batch-migrate.sh` writes completed sites to `config/batch-done.tsv` and skips
  them on re-runs. Use `--force` to ignore the resume state.
- Failed sites are recorded in `config/batch-failed.tsv`. Re-run only those with
  `./batch-migrate.sh --retry-failed`.
- `batch-migrate-ploi-source.sh` uses `config/batch-ploi-source-done.tsv` and
  `config/batch-ploi-source-failed.tsv` the same way; retry with
  `./batch-migrate-ploi-source.sh --retry-failed`.
- `batch-migrate-ploi.sh` is currently stateless — use `--limit` and re-run by
  editing the CSV.

## Safety

`.env`, `downloads/`, `backups/`, `reports/`, `config/`, `logs/` and local credential files are git-ignored
and **never** committed. Only the scripts and templates are version-controlled.

## Requirements

`bash`, `ssh`, `scp`, `ssh-keygen`, `rsync`, `zip`, `unzip`, `curl`, `jq`.

For R2 uploads you also need one of:

- [`rclone`](https://rclone.org) (recommended — handles presigned URLs automatically), or
- [AWS CLI v2](https://aws.amazon.com/cli/) configured to use environment credentials.

## Cloudflare token permissions

Depending on which features you use, your Cloudflare API token needs different
permissions:

| Feature | Required token permissions |
|---|---|
| DNS checks in `migrate-cli.py` / `migrate` | `Zone:Read`, `DNS:Edit` |
| Sending backup emails via `backup runcloud` | `Email Send` |
| Uploading to R2 | Uses **R2 S3-compatible credentials** (`R2_ACCESS_KEY_ID` + `R2_SECRET_ACCESS_KEY`) created in the R2 dashboard, not the Cloudflare API token. |

If you prefer one token for everything, add `Email Send` to the existing token
that already has `Zone:Read` + `DNS:Edit`. R2 still needs its own S3-compatible
keys, which do not use the Cloudflare API token format.
