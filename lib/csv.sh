# shellcheck shell=bash
# lib/csv.sh - simple positional CSV normalizer for shell batch scripts.
#
# Requires functions from lib/env.sh (trim) and lib/output.sh (warn).
# Sourcing through lib/common.sh provides them.
#
# read_batch_csv <file> [known_headers...]
#   Reads a CSV file and prints one normalized tab-separated row per line.
#   Skips:
#     - blank lines
#     - lines whose first trimmed field starts with '#'
#     - rows whose first trimmed field (lowercased) matches any known header
#   Each output line has fields separated by literal tabs. Fields are trimmed
#   and CR characters are stripped. Empty trailing fields are preserved so
#   callers can still read them into variables.
#
# Typical caller pattern:
#   while IFS=$'\t' read -r user ip domain; do
#     [ -n "$user" ] || continue
#     ...
#   done < <(read_batch_csv "$CSV" user)

read_batch_csv() {
  local file="$1"; shift
  local headers="$*"
  [ -f "$file" ] || { warn "CSV not found: $file"; return 1; }

  local line fields i first h
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue

    IFS=',' read -r -a fields <<< "$line"
    [ "${#fields[@]}" -eq 0 ] && continue

    for i in "${!fields[@]}"; do
      fields[i]="$(trim "${fields[$i]}")"
    done
    first="${fields[0],,}"

    for h in $headers; do
      [ "$first" = "$h" ] && continue 2
    done

    # emit as tab-separated row
    printf '%s' "${fields[0]}"
    for ((i=1; i<${#fields[@]}; i++)); do
      printf '\t%s' "${fields[$i]}"
    done
    printf '\n'
  done < "$file"
}