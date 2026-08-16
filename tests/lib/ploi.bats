#!/usr/bin/env bats
# Tests for lib/ploi.sh - Ploi API client.

setup() {
  # shellcheck source=../../lib/common.sh
  . "${BATS_TEST_DIRNAME}/../../lib/common.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$BIN"
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl for testing ploi_curl.
if [[ "$*" == *"--help"* ]]; then
  echo "Usage: curl [options...] <url>"
  echo "     --fail-with-body"
  echo "     --fail"
  exit 0
fi

# last argument is the URL
url="${!#}"
echo "URL=$url"

# which fail flag was used?
case "$*" in
  *--fail-with-body*) echo "FLAG=--fail-with-body" ;;
  *--fail*)           echo "FLAG=--fail" ;;
esac

# capture -X and -H arguments
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -X) echo "METHOD=${args[$((i+1))]}" ;;
    -H) echo "HEADER=${args[$((i+1))]}" ;;
  esac
done

# simulate HTTP failure on any URL ending in /bad
if [[ "$url" == */bad ]]; then
  exit 22
fi
exit 0
EOF
  chmod +x "$BIN/curl"
  PATH="$BIN:$PATH"
  export PLOI_API_TOKEN="test-token"
  export PLOI_API_URL="https://test.ploi.example/api"
}

@test "ploi_curl builds URL from relative path" {
  run ploi_curl GET /servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"URL=https://test.ploi.example/api/servers"* ]]
}

@test "ploi_curl passes absolute URL through unchanged" {
  run ploi_curl GET "https://other.example/v1/sites"
  [ "$status" -eq 0 ]
  [[ "$output" == *"URL=https://other.example/v1/sites"* ]]
}

@test "ploi_curl sends required headers" {
  run ploi_curl POST /servers -d '{"name":"x"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEADER=Authorization: Bearer test-token"* ]]
  [[ "$output" == *"HEADER=Accept: application/json"* ]]
  [[ "$output" == *"HEADER=Content-Type: application/json"* ]]
}

@test "ploi_curl uses --fail-with-body when curl supports it" {
  run ploi_curl GET /servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"FLAG=--fail-with-body"* ]]
}

@test "ploi_curl falls back to --fail when curl is old" {
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--help"* ]]; then
  echo "Usage: curl [options...] <url>"
  echo "     --fail"
  exit 0
fi
url="${!#}"
echo "URL=$url"
case "$*" in
  *--fail-with-body*) echo "FLAG=--fail-with-body" ;;
  *--fail*)           echo "FLAG=--fail" ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
  run ploi_curl GET /servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"FLAG=--fail"* ]]
}

@test "ploi_curl propagates curl non-zero exit" {
  run ploi_curl GET /bad
  [ "$status" -ne 0 ]
}