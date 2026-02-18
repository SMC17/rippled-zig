#!/usr/bin/env bash
set -euo pipefail

before_manifest="${1:-/tmp/fixtures-before.sha256}"
after_manifest="${2:-/tmp/fixtures-after.sha256}"
output_md="${3:-artifacts/fixture-refresh/fixture-diff-summary.md}"
output_json="${4:-artifacts/fixture-refresh/fixture-drift.json}"

mkdir -p "$(dirname "$output_md")"

if [[ ! -f "$before_manifest" || ! -f "$after_manifest" ]]; then
  echo "Missing before/after manifest files" >&2
  exit 1
fi

added="$(comm -13 <(sort "$before_manifest") <(sort "$after_manifest") || true)"
removed="$(comm -23 <(sort "$before_manifest") <(sort "$after_manifest") || true)"
changed_count=$(( $(printf '%s\n' "$added" | sed '/^$/d' | wc -l | tr -d ' ') + $(printf '%s\n' "$removed" | sed '/^$/d' | wc -l | tr -d ' ') ))

cat > "$output_md" <<MD
# Fixture Refresh Drift Summary

- Drift entries detected: $changed_count

## Added/Updated Hash Lines
\`\`\`
$added
\`\`\`

## Removed/Previous Hash Lines
\`\`\`
$removed
\`\`\`
MD

jq -n \
  --arg changed_count "$changed_count" \
  --arg added "$added" \
  --arg removed "$removed" \
  '{
    drift_entries: ($changed_count|tonumber),
    added_or_updated_lines: ($added | split("\n") | map(select(length>0))),
    removed_or_previous_lines: ($removed | split("\n") | map(select(length>0)))
  }' > "$output_json"
