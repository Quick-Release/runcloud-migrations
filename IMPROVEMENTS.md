# Codebase improvement tickets

Each ticket is sized so it can be done in one focused pass and leaves the
codebase in a working state. Mark items with `[x]` when completed.

Triage order: do the top three first. They unlock everything else.

---

## High leverage (do first)

- [x] **T1. Extract `load_dotenv` / `save_dotenv` / `prompt` / `confirm` into a shared Python module.** Three identical copies in `backup`, `migrate`, and `migrate-cli.py`. Create `lib/cli_common.py` (or similar) and have all three CLIs `import` from it. Zero behaviour change; ~300 lines of duplicated code collapsed into one source of truth.

- [x] **T2. Delete `ploi_source_curl` and its siblings.** After the token consolidation, `ploi_curl` and `ploi_source_curl` differ only in comments. Update the two callers (`ploi-wp-backup.sh`, `pli-site-info.sh`) to call `ploi_curl`. Delete `pli_source_ssh_opts`, `pli_source_ssh_host`, `pli_source_remote`, `pli_source_scp` only if they have no remaining callers; otherwise keep them as thin aliases.

- [x] **T3. Pull side effects out of `lib/common.sh` source time.** Today, sourcing the file runs `load_env "$PROJECT_ROOT/.env"` and `mkdir -p` on four directories. Make `.env` loading and directory creation explicit calls (e.g. `load_env` and `ensure_dirs`) invoked once by each top-level dispatch script (`migrate`, `batch-migrate.sh`, etc.). Sourcing `lib/common.sh` becomes pure — functions only, no I/O. Unlocks unit-testing the shell side.

---

## Medium leverage (do once the top three are done)

- [x] **T4. Split `lib/common.sh` into focused sub-modules.** Today it is one 400-line file with 17 unrelated functions. Split into (at minimum):
  - `lib/output.sh` — `log`/`warn`/`die`/`step`/`ask`/`ask_yn` + ANSI colors
  - `lib/strings.sh` — `safe_name`/`safe_domain`/`safe_db_name`/`human_bytes`/`random_password`/`trim`/`shquote`/`strip_ansi`
  - `lib/ploi.sh` — `pli_curl` + (post-T2) the SSH adapter family
  - `lib/status.sh` — `init_status`/`update_status`/`get_status`
  
  Keep `lib/common.sh` as a thin shim that `source`s all of them so no caller changes. Goal is locality, not interface change.

- [ ] **T5. Unify the four batch CSV formats behind one helper.** The codebase has four ad-hoc CSV parsers with four slightly different conventions on headers and comments:
  - `clients.csv` (`user,ip[,domain]`) — parsed in `batch-migrate.sh`
  - `clients-ploi.csv` (`system_user,domain`) — parsed in `batch-migrate-ploi-source.sh`
  - `source-servers.csv` (11 columns) — parsed in `migrate`
  - `pli-zips.csv` (`domain,zip_path`) — parsed in `pli-migrate.sh` (verify)
  
  Write one `read_batch_csv(path)` helper that handles comments, blank lines, and optional header rows uniformly. Replace all four call sites. Update the four `.example` files to document one set of conventions.

- [ ] **T6. Make `ask` / `ask_yn` accept their input and output streams.** They currently hardcode fd 0 (`read -r`) and fd 1 (`printf`). Change the signatures so tests can pass fakes:
  ```bash
  ask() { ask_on "$1" "$2" >&2 <&3; }       # default: stdin/stdout behavior
  ask_on() { local prompt="$1" default="$2"; ... read -r reply <&3; printf '%s' "${reply:-$default}"; }
  ```
  Low priority on its own; required before T7.

---

## Testability (depends on T3 and T6)

- [ ] **T7. Add a test harness and the first test.** With T3 done (`lib/common.sh` is now pure at source time) and T6 done (`ask`/`ask_yn` accept injectable streams), write a test for the lowest-risk pure function first:
  - `human_bytes` — pure, ~10 lines, easy to cover
  - `safe_name` / `safe_domain` / `safe_db_name` — pure string sanitizers
  - `ask` / `ask_yn` — verify the BATCH=1 short-circuit and the y/n loop using injected streams
  
  Pick a framework: `bats` for shell, `pytest` for Python. Commit the framework choice before writing more than one test so the patterns are uniform.

- [ ] **T8. Add a fixture-based test for `lib/find-wp.sh`.** Spin up `sshd` in a container with a fake WordPress install; verify the module finds it, extracts the right version/PHP/DB info, and emits the documented `status=ok` key=value contract. This module is already deep and testable — first end-to-end integration test.

- [ ] **T9. Add tests for the Ploi API client.** With T2 done, `pli_curl` is the only API call path. Mock `curl` (or wrap it behind a function variable that tests can override) and verify:
  - relative vs absolute paths in the URL
  - `--fail-with-body` fallback when `curl` is old
  - the `Authorization` / `Accept` / `Content-Type` headers
  - non-2xx responses propagate correctly

---

## Smaller cleanups (do whenever, no dependency)

- [ ] **T10. Replace `_PI_COMMON_LOADED` guard with a per-function check or drop it.** The guard only protects against double-sourcing *in the same shell*, which never happens in practice (each script is a new shell). Once T4 splits the file, the guard becomes irrelevant; either drop it or move it into a tiny `_lib_common_loaded` helper.

- [ ] **T11. Decide whether the Ploi `api_token` / `api_url` columns belong in `source-servers.csv`.** After the consolidation, the per-server token is redundant with the shared `PLOI_API_TOKEN`. Either:
  - drop the columns from the CSV header and the `save_source_server` fieldnames entirely, OR
  - keep them as an explicit per-server override with documented semantics ("blank = use shared token")
  
  Right now they exist but their behaviour is undocumented and inconsistently wired (`run_backup` falls back, `pli_probe` falls back, `ask_new_source_server` does not). Pick one and document.

- [ ] **T12. Document the `BATCH=1` contract.** Multiple modules branch on `BATCH=1` to return defaults silently. Add a single doc block at the top of `lib/common.sh` (or the new `lib/output.sh` post-T4) listing every function that honours `BATCH` and what it does. Right now you have to grep to find out.

- [ ] **T13. Verify `pli-migrate.sh` actually parses `pli-zips.csv`.** The format is documented and an example file ships, but I didn't see the parser in the grep. Confirm the parser exists and matches the documented format, or remove the `.example` file.

---

## Doc / hygiene

- [ ] **T14. Replace remaining non-ASCII glyphs in the other shell scripts and the Python CLIs.** The character cleanup pass touched only `lib/common.sh`. `pli-wp-backup.sh`, `pli-site-info.sh`, `runcloud-wp-backup.sh`, `batch-migrate.sh`, `migrate`, `migrate-cli.py`, `backup`, etc. still contain `─`, `→`, `✔`, `✖`, `—`, `…`. Decide whether to clean all of them or none (consistency matters more than the choice itself).

- [ ] **T15. Add `CONTRIBUTING.md` or extend README with the module conventions.** After T4 the codebase will have a clear shape; capture it in writing so the next contributor doesn't undo it. Document:
  - where new helpers go (`lib/output.sh`, `lib/strings.sh`, `lib/ploi.sh`, `lib/status.sh`)
  - the rule against side effects at source time
  - the rule that modules take env or args, never both for the same thing
  - the shared-Python-module pattern introduced by T1