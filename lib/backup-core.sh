# shellcheck shell=bash
# lib/backup-core.sh - shared tail logic for the backup workers.
#
# The workers (runcloud-wp-backup.sh, ploi-wp-backup.sh, ssh-wp-backup.sh)
# differ in how they discover a WordPress install and dump its database,
# but share the same post-download tail: verify the archive, clean up the
# remote temp dir, clean up the DB dump, record status. These helpers are
# that tail. Discovery/dump logic stays in each worker.
#
# Each remote-taking helper receives the worker's remote-runner function
# NAME as its first argument (e.g. `remote`, `ploi_source_remote`), so the
# same code drives whichever SSH adapter the worker uses.
#
# Defines:
#   verify_backup_zip <zip-path>
#   cleanup_backup_remote_dir <remote-runner> <remote-dir>
#   cleanup_backup_db_dump <remote-runner> <wp-path> <dump-name>
#   finish_backup <site-key> <zip-path>
#
# Env gates (all default "yes"; any other value disables the step):
#   RC_VERIFY_ZIP, RC_CLEANUP_REMOTE_ZIP, RC_CLEANUP_DB_DUMP
#
# Pure at source time: function definitions only. Requires lib/output.sh,
# lib/strings.sh and lib/status.sh (loaded via lib/common.sh).

# verify_backup_zip <zip-path> - integrity-check the downloaded archive.
verify_backup_zip() {
  local zip_path="$1"
  RC_VERIFY_ZIP="${RC_VERIFY_ZIP:-yes}"
  if [ "$RC_VERIFY_ZIP" = "yes" ]; then
    step "Verifying downloaded archive ..."
    unzip -t "$zip_path" >/dev/null 2>&1 || die "downloaded archive is corrupt: $zip_path"
    log "Archive verified"
  fi
}

# cleanup_backup_remote_dir <remote-runner> <remote-dir> - remove the remote
# temp dir holding the zip. Warns where it was left when cleanup is disabled.
cleanup_backup_remote_dir() {
  local run_remote="$1" remote_dir="$2"
  RC_CLEANUP_REMOTE_ZIP="${RC_CLEANUP_REMOTE_ZIP:-yes}"
  if [ "$RC_CLEANUP_REMOTE_ZIP" = "yes" ]; then
    # shellcheck disable=SC2086  # remote command is assembled by design
    "$run_remote" "rm -rf $(shquote "$remote_dir")" || warn "could not remove remote temp dir"
  else
    warn "left remote temp dir: $remote_dir"
  fi
}

# cleanup_backup_db_dump <remote-runner> <wp-path> <dump-name> - remove the
# SQL dump from the source server after it is safely inside the archive.
cleanup_backup_db_dump() {
  local run_remote="$1" wp_path="$2" dump_name="$3"
  RC_CLEANUP_DB_DUMP="${RC_CLEANUP_DB_DUMP:-yes}"
  if [ "$RC_CLEANUP_DB_DUMP" = "yes" ]; then
    step "Cleaning up DB dump on source server ..."
    # shellcheck disable=SC2086  # remote command is assembled by design
    "$run_remote" "rm -f $(shquote "$wp_path/$dump_name")" || warn "could not remove DB dump"
  fi
}

# finish_backup <site-key> <zip-path> - record success and print the result.
finish_backup() {
  local site_key="$1" zip_path="$2"
  echo >&2
  update_status "$site_key" "backed_up" "ok" "zip=$zip_path"
  log "Backup complete: $zip_path"
}
