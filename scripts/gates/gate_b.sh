#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-b}"
mkdir -p "$artifact_dir"

# Deterministic protocol/hash suite.
zig test src/determinism_gate.zig 2>&1 | tee "$artifact_dir/determinism.log"

# Deterministic fixture manifest for tracked test vectors.
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 test_data/*.json | sort > "$artifact_dir/test-data.sha256"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum test_data/*.json | sort > "$artifact_dir/test-data.sha256"
else
  echo "No SHA256 tool found" | tee "$artifact_dir/failure.txt"
  exit 1
fi

line_count=$(wc -l < "$artifact_dir/test-data.sha256" | tr -d ' ')
cat > "$artifact_dir/summary.json" <<JSON
{"gate":"B","status":"pass","fixtures":$line_count}
JSON
