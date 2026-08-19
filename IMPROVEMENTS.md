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

- [ ] **T16. Delete `migrate-cli.py`.** Nothing invokes it; it duplicates
  `ploi_get_servers`, `ploi_pick_server`, `run`, `check_tools`,
  `find_latest_zip`, `configure_target`, and `run_ploi_restore` from `migrate`.
  In an active repo, a duplicated Ploi-API surface is a real risk: fixes
  applied to `migrate` silently don't reach the legacy copy. Update
  `README.md`, `Makefile` (`PYTHON_CLIS`), `CONTRIBUTING.md`, and the
  `migrate-cli.py` reference in `.env.example`. Git history preserves the file.

- [ ] **T17. Extract the shared backup tails into `lib/backup-core.sh` —
  tails only, not a framework.** The four workers (`runcloud-wp-backup.sh`,
  `ploi-wp-backup.sh`, `ssh-wp-backup.sh`, `lib/backup-runcloud.sh`) each
  hand-roll the same ~30-line tail: `unzip -t` verify → cleanup remote zip →
  cleanup DB dump → `update_status` + final log. Variance is only *which*
  remote-runner function is called (`remote`, `ploi_source_remote`) and one
  naming inconsistency (`$DOWNLOADS` vs `$DOWNLOADS_DIR` — unify while there).
  Helpers take the remote-runner function name as an argument. The discovery /
  dump logic stays per-worker: that variance is genuine (RunCloud webapps,
  Ploi admin reading `wp-config.php`, generic siteurl search). Must ship with
  `tests/lib/backup-core.bats`. Do **not** attempt a unified pipeline — the
  four paths touch production data mid-campaign.

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

- [ ] **T19. Finish T1: fold `run()` / `check_tools()` into
  `lib/cli_common.py`.** `run()` is byte-identical between `migrate` and
  `backup`; `check_tools()` differs only in the required-tools list —
  parameterize it as `check_tools(tools)`. Post-T16 there are exactly two
  Python CLIs. Leave the Ploi API functions in `migrate`: with the legacy CLI
  gone there is a single caller, so moving them is speculative.

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
