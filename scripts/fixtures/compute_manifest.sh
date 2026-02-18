#!/usr/bin/env bash
set -euo pipefail

target_dir="${1:-test_data}"

if [[ ! -d "$target_dir" ]]; then
  echo "Missing fixture directory: $target_dir" >&2
  exit 1
fi

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    echo "No SHA256 tool found (need shasum or sha256sum)" >&2
    exit 1
  fi
}

find "$target_dir" -maxdepth 1 -type f -name '*.json' | sort | while read -r file; do
  rel="${file#./}"
  printf '%s  %s\n' "$(hash_file "$file")" "$rel"
done
