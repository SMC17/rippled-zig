#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-a}"
mkdir -p "$artifact_dir"

expected_zig="${ZIG_VERSION_EXPECTED:-0.15.1}"
actual_zig="$(zig version)"
printf '{"expected":"%s","actual":"%s"}\n' "$expected_zig" "$actual_zig" > "$artifact_dir/toolchain.json"

if [[ "$actual_zig" != "$expected_zig" ]]; then
  echo "Zig version mismatch: expected $expected_zig, got $actual_zig" | tee "$artifact_dir/failure.txt"
  exit 1
fi

zig build 2>&1 | tee "$artifact_dir/build.log"
zig build test 2>&1 | tee "$artifact_dir/test.log"
zig fmt --check . 2>&1 | tee "$artifact_dir/fmt.log"

cat > "$artifact_dir/summary.json" <<JSON
{"gate":"A","status":"pass","zig":"$actual_zig"}
JSON
