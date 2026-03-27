#!/usr/bin/env bash
# Gate B -- Deterministic Serialization / Hash Fixture Pinning
# v1-hardened: enforces minimum vector count, fixture manifest integrity,
# byte-level reproducibility, and cross-run determinism.
set -euo pipefail

artifact_dir="${1:-artifacts/gate-b}"
mkdir -p "$artifact_dir"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

min_vector_hashes="${GATE_B_MIN_VECTOR_HASHES:-18}"
min_fixture_files="${GATE_B_MIN_FIXTURE_FILES:-5}"

fail() {
  local reason="$1"
  local escaped_reason="${reason//\"/\\\"}"
  echo "$reason" | tee "$artifact_dir/failure.txt"
  cat > "$artifact_dir/summary.json" <<JSON
{
  "gate": "B",
  "status": "fail",
  "timestamp_utc": "$ts_iso",
  "reason": "$escaped_reason"
}
JSON
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Run the deterministic protocol/hash suite via the build graph
# ---------------------------------------------------------------------------
echo ">>> Determinism suite"
zig build gate-b 2>&1 | tee "$artifact_dir/determinism.log"

# ---------------------------------------------------------------------------
# 2. Extract and validate VECTOR_HASH evidence from test output
# ---------------------------------------------------------------------------
echo ">>> Vector hash validation"
grep '^VECTOR_HASH ' "$artifact_dir/determinism.log" > "$artifact_dir/vector-manifest.txt" || true
vector_count="$(wc -l < "$artifact_dir/vector-manifest.txt" | tr -d ' ')"

if (( vector_count < min_vector_hashes )); then
  fail "Insufficient deterministic vector evidence: expected >=$min_vector_hashes got $vector_count"
fi

# Verify no duplicate vector names (each vector must be uniquely named).
vector_names="$(awk '{print $2}' "$artifact_dir/vector-manifest.txt" | sort)"
unique_names="$(echo "$vector_names" | sort -u)"
if [[ "$vector_names" != "$unique_names" ]]; then
  fail "Duplicate vector names detected in VECTOR_HASH output"
fi

# Verify every hash is a valid hex string of expected length (SHA-256 = 64 hex chars).
bad_hashes="$(awk '$3 !~ /^[0-9a-f]{64}$/ {print $2, $3}' "$artifact_dir/vector-manifest.txt" || true)"
if [[ -n "$bad_hashes" ]]; then
  fail "Malformed vector hash(es) detected: $bad_hashes"
fi

# ---------------------------------------------------------------------------
# 3. Cross-run determinism: run the suite a second time and diff
# ---------------------------------------------------------------------------
echo ">>> Cross-run determinism check"
zig build gate-b 2>&1 | tee "$artifact_dir/determinism-run2.log"
grep '^VECTOR_HASH ' "$artifact_dir/determinism-run2.log" > "$artifact_dir/vector-manifest-run2.txt" || true

if ! diff -u "$artifact_dir/vector-manifest.txt" "$artifact_dir/vector-manifest-run2.txt" > "$artifact_dir/cross-run.diff"; then
  fail "Cross-run determinism failure: vector hashes differ between two consecutive runs"
fi

# ---------------------------------------------------------------------------
# 4. Fixture manifest computation and drift detection
# ---------------------------------------------------------------------------
echo ">>> Fixture manifest"

if [[ ! -x "$ROOT_DIR/scripts/fixtures/compute_manifest.sh" ]]; then
  fail "Missing fixture manifest script: scripts/fixtures/compute_manifest.sh"
fi

"$ROOT_DIR/scripts/fixtures/compute_manifest.sh" test_data > "$artifact_dir/test-data.sha256"

fixture_count="$(wc -l < "$artifact_dir/test-data.sha256" | tr -d ' ')"
if (( fixture_count < min_fixture_files )); then
  fail "Fixture manifest has too few entries: expected >=$min_fixture_files got $fixture_count"
fi

# Committed baseline must exist.
committed_manifest="$ROOT_DIR/test_data/fixture_manifest.sha256"
if [[ ! -f "$committed_manifest" ]]; then
  fail "Missing committed fixture manifest: test_data/fixture_manifest.sha256"
fi

# Ensure committed manifest is non-empty.
committed_lines="$(wc -l < "$committed_manifest" | tr -d ' ')"
if (( committed_lines < 1 )); then
  fail "Committed fixture manifest is empty: test_data/fixture_manifest.sha256"
fi

# Diff against committed baseline.
if ! diff -u "$committed_manifest" "$artifact_dir/test-data.sha256" > "$artifact_dir/fixture-manifest.diff"; then
  echo "--- Fixture manifest drift ---"
  cat "$artifact_dir/fixture-manifest.diff" | head -40
  fail "Fixture manifest drift detected. Refresh fixtures via fixture-refresh workflow and commit reviewed updates."
fi

# ---------------------------------------------------------------------------
# 5. Verify every fixture file referenced in the manifest actually exists
# ---------------------------------------------------------------------------
echo ">>> Fixture file existence check"
missing_fixtures=""
while IFS=' ' read -r _sha filepath; do
  if [[ ! -f "$ROOT_DIR/$filepath" ]]; then
    missing_fixtures="$missing_fixtures $filepath"
  fi
done < "$artifact_dir/test-data.sha256"

if [[ -n "$missing_fixtures" ]]; then
  fail "Fixture files referenced in manifest but missing on disk:$missing_fixtures"
fi

# ---------------------------------------------------------------------------
# 6. Verify no fixture file has zero bytes (corrupt/truncated fixture)
# ---------------------------------------------------------------------------
echo ">>> Fixture integrity check"
empty_fixtures=""
while IFS=' ' read -r _sha filepath; do
  if [[ -f "$ROOT_DIR/$filepath" ]]; then
    size="$(wc -c < "$ROOT_DIR/$filepath" | tr -d ' ')"
    if (( size == 0 )); then
      empty_fixtures="$empty_fixtures $filepath"
    fi
  fi
done < "$artifact_dir/test-data.sha256"

if [[ -n "$empty_fixtures" ]]; then
  fail "Empty fixture files detected (0 bytes):$empty_fixtures"
fi

# ---------------------------------------------------------------------------
# 7. JSON fixture structural validation
# ---------------------------------------------------------------------------
echo ">>> JSON fixture validation"
json_errors=""
while IFS=' ' read -r _sha filepath; do
  if [[ "$filepath" == *.json && -f "$ROOT_DIR/$filepath" ]]; then
    if ! jq empty "$ROOT_DIR/$filepath" 2>/dev/null; then
      json_errors="$json_errors $filepath"
    fi
  fi
done < "$artifact_dir/test-data.sha256"

if [[ -n "$json_errors" ]]; then
  fail "Invalid JSON in fixture files:$json_errors"
fi

# ---------------------------------------------------------------------------
# 8. Summary artifact
# ---------------------------------------------------------------------------
cat > "$artifact_dir/summary.json" <<JSON
{
  "gate": "B",
  "status": "pass",
  "timestamp_utc": "$ts_iso",
  "fixtures": $fixture_count,
  "vector_hashes": $vector_count,
  "cross_run_deterministic": true,
  "fixture_manifest_drift": false,
  "thresholds": {
    "min_vector_hashes": $min_vector_hashes,
    "min_fixture_files": $min_fixture_files
  }
}
JSON

echo "Gate B: PASS"
