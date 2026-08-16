#!/usr/bin/env bash
#
# lib/r2-upload.sh
# ----------------------------------------------------------------------------
# Upload a local file to a Cloudflare R2 bucket and return a download URL.
#
# Supports two upload tools:
#   1. rclone  (preferred for simple presigned URLs)
#   2. aws CLI (fallback)
#
# Usage:
#   lib/r2-upload.sh <local-file> <r2-object-key>
#
# Required env:
#   R2_BUCKET, R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
#
# Optional env:
#   R2_PUBLIC_DOMAIN   - if set, return https://<domain>/<key> instead of a
#                        presigned URL (the bucket must be publicly readable).
#   R2_URL_TTL_SECONDS - presigned URL lifetime; default 2592000 (30 days).
# ----------------------------------------------------------------------------

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env "$PROJECT_ROOT/.env"
mkdir -p "$DOWNLOADS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$SERVERS_DIR" "$(dirname "$STATUS_FILE")"


[ $# -ge 2 ] || die "usage: $0 <local-file> <r2-object-key>"
LOCAL_FILE="$1"
OBJECT_KEY="$2"

[ -f "$LOCAL_FILE" ] || die "file not found: $LOCAL_FILE"
[ -n "${R2_BUCKET:-}" ] || die "R2_BUCKET is not set"
[ -n "${R2_ACCOUNT_ID:-}" ] || die "R2_ACCOUNT_ID is not set"
[ -n "${R2_ACCESS_KEY_ID:-}" ] || die "R2_ACCESS_KEY_ID is not set"
[ -n "${R2_SECRET_ACCESS_KEY:-}" ] || die "R2_SECRET_ACCESS_KEY is not set"

TTL_SECONDS="${R2_URL_TTL_SECONDS:-2592000}"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

step "Uploading $(basename "$LOCAL_FILE") to R2 bucket $R2_BUCKET ..."

# Prefer rclone when available; configure it purely through env vars so no
# persistent config file is required.
if command -v rclone >/dev/null 2>&1; then
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"

  rclone copyto "$LOCAL_FILE" "r2:${R2_BUCKET}/${OBJECT_KEY}" || die "rclone upload failed"
  log "Uploaded to r2://${R2_BUCKET}/${OBJECT_KEY}"

  if [ -n "${R2_PUBLIC_DOMAIN:-}" ]; then
    printf 'https://%s/%s\n' "$R2_PUBLIC_DOMAIN" "$OBJECT_KEY"
  else
    # rclone --expire takes Go duration; 720h = 30 days
    rclone link "r2:${R2_BUCKET}/${OBJECT_KEY}" --expire "${TTL_SECONDS}s" || die "could not create R2 presigned URL"
  fi
  exit 0
fi

# Fallback to the AWS CLI with the S3-compatible endpoint.
if command -v aws >/dev/null 2>&1; then
  aws s3 cp "$LOCAL_FILE" "s3://${R2_BUCKET}/${OBJECT_KEY}" \
    --endpoint-url="$R2_ENDPOINT" || die "aws s3 upload failed"
  log "Uploaded to s3://${R2_BUCKET}/${OBJECT_KEY}"

  if [ -n "${R2_PUBLIC_DOMAIN:-}" ]; then
    printf 'https://%s/%s\n' "$R2_PUBLIC_DOMAIN" "$OBJECT_KEY"
  else
    aws s3 presign "s3://${R2_BUCKET}/${OBJECT_KEY}" \
      --endpoint-url="$R2_ENDPOINT" \
      --expires-in "$TTL_SECONDS" || die "could not create R2 presigned URL"
  fi
  exit 0
fi

die "No R2 upload tool found. Install rclone (https://rclone.org) or the AWS CLI v2."
