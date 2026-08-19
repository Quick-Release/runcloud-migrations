# Contributing to runcloud-migrations

This repo is a toolkit of shell scripts and small Python CLIs for migrating
WordPress sites from RunCloud / Ploi / Coolify / plain SSH onto Ploi. The
codebase is organised for locality: each module has a narrow job, and
callers compose them.

## Layout

```text
lib/
  common.sh        - thin shim; sourcing this loads the lib/*.sh family
  csv.sh           - positional CSV normalizer for batch scripts
  env.sh           - .env loader (load_env, trim)
  output.sh        - terminal output + prompts (log/warn/die/step, ask/ask_yn)
  strings.sh       - pure string helpers (safe_*, human_bytes, shquote, ...)
  status.sh        - status.tsv tracking (init/update/get_status)
  ploi.sh          - Ploi API client + SSH adapter family
  backup-core.sh    - shared backup tail (verify/cleanup/finish helpers
                     used by the backup workers)
  cli_common.py    - shared helpers for the Python CLIs (load_dotenv,
                     save_dotenv, prompt, confirm, expand_path)
  find-wp.sh       - deep module: probe a server for a WordPress install
  backup-runcloud.sh - RunCloud-specific backup orchestration
  r2-upload.sh     - Cloudflare R2 upload helper
```

## Rules

### 1. No side effects at source time

Sourcing `lib/common.sh` must be pure: it defines functions and variables,
but it does **not** read files, create directories, or call APIs. Dispatch
scripts call `load_env "$PROJECT_ROOT/.env"` and `mkdir -p ...` explicitly
after sourcing. This makes the shell side testable.

### 2. Modules take environment *or* arguments, not both for the same thing

For example, `ploi_curl` reads `PLOI_API_TOKEN` from the environment; it does
not accept a token argument. If you need a different token, set a different
env var in the child process. Keep the seam at the process boundary.

### 3. Add helpers to the right module

- New output/prompt behaviour → `lib/output.sh`
- New string sanitizers or pure helpers → `lib/strings.sh`
- New Ploi API or SSH behaviour → `lib/ploi.sh`
- New .env or CSV behaviour → `lib/env.sh` / `lib/csv.sh`
- New Python helper used by more than one CLI → `lib/cli_common.py`

Avoid adding unrelated functions to `lib/common.sh`; it is only a loader.

### 4. Shared Python helpers live in `lib/cli_common.py`

Any helper used by both `backup` and `migrate` belongs in
`lib/cli_common.py`. Do not copy the helper into another CLI.

### 5. BATCH=1 contract

Both shell and Python prompts must honour `BATCH=1` by returning their
default silently:

- Shell: `ask()`, `ask_yn()`, `ask_in()`, `ask_yn_in()` in `lib/output.sh`
- Python: `prompt()`, `confirm()` in `lib/cli_common.py`

Callers set `BATCH=1` when running child scripts unattended.

### 6. Batch CSV conventions

Simple positional CSVs (`clients.csv`, `clients-ploi.csv`, `ploi-zips.csv`)
are normalized through `lib/csv.sh`:

- `#` lines are comments.
- Blank lines are ignored.
- Header rows whose first field matches a known header word are auto-skipped.
- Fields are trimmed and emitted tab-separated.

`source-servers.csv` is different: it has many columns and is parsed with
`csv.DictReader` by the `migrate` Python CLI. Keep it header-based.

## Tests

We use [bats-core](https://github.com/bats-core/bats-core) for shell tests.

```bash
# run all tests
make test

# run one file
bats tests/lib/strings.bats
```

Add a new `.bats` file under `tests/lib/` for the module you changed. Keep
tests isolated (use `$BATS_TEST_TMPDIR` for temp files) and avoid touching
the real `.env` or remote servers. The find-wp fixture
(`tests/fixtures/find-wp/`) shows the hermetic pattern: a fake `ssh` on
`PATH` runs the probe's remote commands against a local fixture tree, with
search roots pinned via `FIND_WP_ROOTS` so nothing on the host leaks in.

CI (`.github/workflows/ci.yml`) runs `make lint && make test` on every push
to `main` and every pull request. Both must pass before a change is merged.

## Lint

```bash
make lint
```

This runs `shellcheck` on all shell scripts and `python3 -m py_compile` on
the Python CLIs. Both must pass before a change is pushed.