# Codebase improvement tickets

Each ticket is sized so it can be done in one focused pass and leaves the
codebase in a working state. Mark items with `[x]` when completed.

---

## Round 2 — active-migration hardening (current)

Context: migrations are ongoing, so round 2 optimizes for robustness and
lower maintenance surface. Decisions recorded 2025-ish grilling session:
delete dead code, dedup conservatively, enforce with CI.

Triage order: T18 first (green baseline for everything after), then the rest
is independent.

- [x] **T16. Delete `migrate-cli.py`.** Done: file removed; references
  cleaned in `README.md`, `Makefile` (`PYTHON_CLIS`), `CONTRIBUTING.md`,
  `.env.example`, and the `lib/cli_common.py` docstring. The duplicated
  Ploi-API surface is gone; `migrate` is the single Python migration CLI.
  Git history preserves the legacy file.

- [x] **T17. Extract the shared backup tails into `lib/backup-core.sh` —
  tails only, not a framework.** Done: `verify_backup_zip`,
  `cleanup_backup_remote_dir`, `cleanup_backup_db_dump` and `finish_backup`
  (remote-runner passed by function name) now close out all three bash
  workers; loaded via `lib/common.sh`, covered by
  `tests/lib/backup-core.bats`. `$DOWNLOADS` alias dropped for
  `$DOWNLOADS_DIR` everywhere. One honest correction to the ticket's
  premise: `lib/backup-runcloud.sh`'s tail is a different contract (R2
  upload, size verification, key=value output for the Python `backup`
  CLI) — only its remote-temp cleanup matched, so only that call was
  shared; forcing the rest would have been the framework this ticket
  forbade. Two small unifications sanctioned by the ticket: the corrupt-
  archive die message now always includes the path, and
  `cleanup_backup_remote_dir` warns where the temp dir was left when
  cleanup is disabled (was a silent skip in two workers); the Python
  worker's remote cleanup is now gated by `RC_CLEANUP_REMOTE_ZIP` like
  the others (default `yes` = old behaviour).

- [x] **T18. Add minimal CI.** Done: `.github/workflows/ci.yml` runs
  `make lint && make test` on pushes to `main` and PRs (ubuntu runner;
  bats-core via npm; shellcheck/python ship with the runner). Getting the
  suite green surfaced three latent problems, all fixed with this ticket:
  the find-wp fixture binaries were committed without exec bits (and its
  fake `ssh` resolved `HOME` through a symlink, so the fixture `wp` was
  never on `PATH`); the probe scanned real host roots (now containable via
  `FIND_WP_ROOTS`); and `lib/find-wp.sh` / `ssh-wp-backup.sh` used unquoted
  `printf wp\n` markers — bash strips unquoted backslashes, so wp-cli
  detection has always returned `wpn`/`nonen` and the SSH probe could
  never match a site. All remote markers are now `echo`-based.

- [x] **T19. Finish T1: fold `run()` / `check_tools()` into
  `lib/cli_common.py`.** Done: `run()` moved verbatim; `check_tools(tools,
  any_of=(), any_of_hint="")` replaces the two per-CLI copies — the
  `any_of` group carries what was backup's hardcoded rclone/aws R2 check,
  with the install hint preserved. `backup` keeps its single-caller
  `run_capture()` / `human_bytes()` locally. The Ploi API functions stay
  in `migrate` (single caller). Six new bats cases in
  `tests/lib/cli_common.bats`; both CLIs smoke-tested through their real
  `check_tools` call sites. One wording delta: the R2 missing-tool error
  now reads `Missing a required tool (any of: rclone, aws).` + hint.

- [ ] **T20. Backfill `tests/lib/env.bats` and `tests/lib/status.bats`.**
  `lib/env.sh` (load_env, trim) and `lib/status.sh` (init/update/get over a
  temp status.tsv) are small, mostly-pure, and cheap to cover — rounds `lib/`
  to full unit coverage. No backfill for the batch dispatchers or
  `lib/r2-upload.sh`: thin orchestration and external-tool wrappers where
  mocks prove little.

- [x] **Housekeeping: fix the two SC2015 lint failures.** Done alongside
  this round: `lib/backup-runcloud.sh` and `ssh-wp-backup.sh` now use
  explicit `if` instead of `A && B || C`; `make lint` is green again.

---

## Round 1 (complete)

All fifteen tickets done. Highlights: shared `lib/cli_common.py` (T1),
pure-at-source-time `lib/common.sh` split into focused modules (T3/T4),
unified batch CSV parsing behind `lib/csv.sh` (T5/T13), injectable prompt
streams + bats harness (T6/T7), single Ploi API client `ploi_curl` (T2/T9),
documented `BATCH=1` contract and module conventions (T12/T15), ASCII-only
output (T14).

T8 was satisfied differently than written: instead of an sshd-in-container
test, `tests/lib/find-wp.bats` + `tests/fixtures/find-wp/` use a fake `ssh`
executable on `PATH` that executes the probe's remote commands against a
local fixture filesystem. Same coverage of orchestration and the `status=ok`
key=value contract, no Docker, runs anywhere. Accepted as done.
