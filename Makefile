.PHONY: test lint

# Shell scripts that are checked by shellcheck (sourced + dispatch)
SHELL_SCRIPTS := \
  lib/common.sh lib/csv.sh lib/env.sh lib/output.sh lib/strings.sh lib/status.sh lib/ploi.sh \
  lib/backup-runcloud.sh lib/find-wp.sh lib/r2-upload.sh \
  batch-migrate-ploi-source.sh batch-migrate-ploi.sh batch-migrate.sh \
  coolify-remove.sh migrate.sh ploi-migrate.sh ploi-site-info.sh \
  ploi-to-ploi.sh ploi-wp-backup.sh runcloud-site-info.sh \
  runcloud-wp-backup.sh ssh-wp-backup.sh

PYTHON_CLIS := migrate migrate-cli.py backup

test:
	bats tests/lib/*.bats

lint:
	shellcheck $(SHELL_SCRIPTS)
	python3 -m py_compile $(PYTHON_CLIS)