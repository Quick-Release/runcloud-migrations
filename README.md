# runcloud-migrations

A small Bash toolkit for migrating WordPress sites **off RunCloud** and **onto Ploi**, in two phases.

```
RunCloud server  ──backup──▶  ./downloads/<domain>_<ts>.zip  ──migrate──▶  Ploi server
```

## What's here

| File | Purpose |
|------|---------|
| `runcloud-wp-backup.sh` | Connects to a RunCloud server over SSH, finds the WordPress install (wp-cli), exports the DB, zips the whole site, and downloads it as `<domain>_<timestamp>.zip`. |
| `batch-migrate.sh` | Runs the backup for every site in `clients.csv`, unattended (resume, per-site failure isolation, logging). |
| `lib/common.sh` | Shared helpers + the `.env` loader used by all scripts. |
| `.env.example` | Template for configuration — copy to `.env` and fill in. |
| `clients.csv.example` | Template CSV (one site per line: `user,ip[,domain]`). |

> The **Ploi migration** scripts (`ploi-migrate.sh`, `batch-migrate-ploi.sh`) are the next phase.

## Quick start

```bash
cp .env.example .env        # fill in SSH key/port (and later Ploi details)
cp clients.csv.example clients.csv   # add your sites

./runcloud-wp-backup.sh                 # back up one site (interactive)
# or, in bulk:
./batch-migrate.sh --dry-run            # preview
./batch-migrate.sh                      # run for real
```

Backups land in `./downloads/`.

## Configuration (`.env`)

Every script auto-loads `.env` from the project root. **Real environment variables
always win** over `.env`, so `FOO=bar ./script` overrides the file. See
[`.env.example`](.env.example) for the full list and defaults.

Key variables:

- `SSH_KEY` / `SSH_PORT` — RunCloud SSH access
- `CLIENTS_CSV` — the CSV used by the batch wrapper

(Ploi-side variables — API token, server, SSH, migration behavior — are documented
in `.env.example` and used by the upcoming Ploi scripts.)

## Safety

`.env`, `downloads/`, `config/`, and `logs/` are git-ignored and **never** committed —
they hold secrets and client data. Only the scripts and templates are version-controlled.

## Requirements

`bash`, `ssh`, `scp`, `rsync`, `zip`, `curl`. (`jq` is additionally required for the
Ploi phase.)
