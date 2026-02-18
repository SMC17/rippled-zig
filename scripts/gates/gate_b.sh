#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-b}"
mkdir -p "$artifact_dir"

# Deterministic protocol/hash suite through build graph (injects build options).
zig build gate-b 2>&1 | tee "$artifact_dir/determinism.log"

# Deterministic vector evidence emitted by src/determinism_check.zig.
grep '^VECTOR_HASH ' "$artifact_dir/determinism.log" > "$artifact_dir/vector-manifest.txt" || true
vector_count="$(wc -l < "$artifact_dir/vector-manifest.txt" | tr -d ' ')"
if (( vector_count < 8 )); then
  echo "Insufficient deterministic vector evidence: expected >=8 got $vector_count" | tee "$artifact_dir/failure.txt"
  exit 1
fi

# Deterministic fixture manifest for tracked test vectors.
scripts/fixtures/compute_manifest.sh test_data > "$artifact_dir/test-data.sha256"

# Fixture baseline must match committed manifest unless intentionally updated.
if [[ ! -f test_data/fixture_manifest.sha256 ]]; then
  echo "Missing committed fixture manifest: test_data/fixture_manifest.sha256" | tee "$artifact_dir/failure.txt"
  exit 1
fi
if ! diff -u test_data/fixture_manifest.sha256 "$artifact_dir/test-data.sha256" > "$artifact_dir/fixture-manifest.diff"; then
  echo "Fixture manifest drift detected. Refresh fixtures via fixture-refresh workflow and commit reviewed updates." | tee "$artifact_dir/failure.txt"
  exit 1
fi

line_count=$(wc -l < "$artifact_dir/test-data.sha256" | tr -d ' ')
cat > "$artifact_dir/summary.json" <<JSON
{"gate":"B","status":"pass","fixtures":$line_count,"vector_hashes":$vector_count}
JSON
