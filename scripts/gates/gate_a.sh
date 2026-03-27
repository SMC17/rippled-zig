#!/usr/bin/env bash
# Gate A -- Build / Test / Format / Warning-free compilation
# v1-hardened: exits non-zero on any warning, test failure, or format drift.
set -euo pipefail

artifact_dir="${1:-artifacts/gate-a}"
mkdir -p "$artifact_dir"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ---------------------------------------------------------------------------
# 1. Resolve and pin the Zig toolchain
# ---------------------------------------------------------------------------
expected_zig="${ZIG_VERSION_EXPECTED:-$(awk '/^zig / { print $2; exit }' "$ROOT_DIR/.tool-versions" 2>/dev/null || echo 0.14.1)}"

if ! zig_bin="$("$ROOT_DIR/scripts/resolve_zig.sh" 2> "$artifact_dir/failure.txt")"; then
  actual_zig="$(zig version 2>/dev/null || printf 'missing')"
  printf '{"expected":"%s","actual":"%s"}\n' "$expected_zig" "$actual_zig" > "$artifact_dir/toolchain.json"
  cat "$artifact_dir/failure.txt"
  exit 1
fi

actual_zig="$("$zig_bin" version)"
printf '{"expected":"%s","actual":"%s"}\n' "$expected_zig" "$actual_zig" > "$artifact_dir/toolchain.json"

if [[ "$actual_zig" != "$expected_zig" ]]; then
  echo "Toolchain version mismatch: expected=$expected_zig actual=$actual_zig" | tee "$artifact_dir/failure.txt"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Build -- capture stderr separately to detect warnings
# ---------------------------------------------------------------------------
echo ">>> Build"
build_exit=0
"$zig_bin" build -Dsecp256k1=true --summary all \
  > "$artifact_dir/build-stdout.log" \
  2> "$artifact_dir/build-stderr.log" || build_exit=$?

cat "$artifact_dir/build-stdout.log" "$artifact_dir/build-stderr.log" > "$artifact_dir/build.log"

if (( build_exit != 0 )); then
  echo "Build failed with exit code $build_exit" | tee "$artifact_dir/failure.txt"
  cat "$artifact_dir/build-stderr.log"
  exit 1
fi

# Fail on any compiler warning (the string "warning:" appears in Zig compiler output).
if grep -qiE '^(src/|\./).*(warning|error):' "$artifact_dir/build-stderr.log" 2>/dev/null; then
  echo "Build produced warnings -- Gate A requires warning-free compilation" | tee "$artifact_dir/failure.txt"
  grep -iE 'warning:' "$artifact_dir/build-stderr.log" | head -20
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Test suite
# ---------------------------------------------------------------------------
echo ">>> Tests"
test_exit=0
"$zig_bin" build -Dsecp256k1=true test \
  > "$artifact_dir/test-stdout.log" \
  2> "$artifact_dir/test-stderr.log" || test_exit=$?

cat "$artifact_dir/test-stdout.log" "$artifact_dir/test-stderr.log" > "$artifact_dir/test.log"

if (( test_exit != 0 )); then
  echo "Tests failed with exit code $test_exit" | tee "$artifact_dir/failure.txt"
  cat "$artifact_dir/test-stderr.log"
  exit 1
fi

# Extract pass/fail counts from Zig test runner output if available.
test_passed="$(grep -oE '[0-9]+ passed' "$artifact_dir/test.log" | awk '{print $1}' || echo 0)"
test_failed="$(grep -oE '[0-9]+ failed' "$artifact_dir/test.log" | awk '{print $1}' || echo 0)"
test_skipped="$(grep -oE '[0-9]+ skipped' "$artifact_dir/test.log" | awk '{print $1}' || echo 0)"

if [[ "$test_failed" != "0" && -n "$test_failed" ]]; then
  echo "Test failures detected: $test_failed failed" | tee "$artifact_dir/failure.txt"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Format check -- entire project
# ---------------------------------------------------------------------------
echo ">>> Format check"
fmt_exit=0
"$zig_bin" fmt --check . > "$artifact_dir/fmt.log" 2>&1 || fmt_exit=$?

if (( fmt_exit != 0 )); then
  echo "Formatting drift detected -- run 'zig fmt .' and commit" | tee "$artifact_dir/failure.txt"
  cat "$artifact_dir/fmt.log" | head -40
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Source hygiene checks
# ---------------------------------------------------------------------------
echo ">>> Source hygiene"

# Ensure no checked-in binaries or large blobs snuck in.
large_files=""
while IFS= read -r -d '' f; do
  size="$(wc -c < "$f" | tr -d ' ')"
  if (( size > 1048576 )); then
    large_files="$large_files $f($size bytes)"
  fi
done < <(find "$ROOT_DIR/src" "$ROOT_DIR/tests" -type f -print0 2>/dev/null || true)

if [[ -n "$large_files" ]]; then
  echo "Source tree contains files >1 MB:$large_files" | tee "$artifact_dir/failure.txt"
  exit 1
fi

# Check for .env / credential files that should never be committed.
secret_files=""
for pattern in ".env" "credentials.json" "*.pem" "*.key"; do
  while IFS= read -r -d '' f; do
    secret_files="$secret_files $f"
  done < <(find "$ROOT_DIR" -maxdepth 3 -name "$pattern" -not -path '*/.zig-cache/*' -not -path '*/zig-out/*' -print0 2>/dev/null || true)
done

if [[ -n "$secret_files" ]]; then
  echo "Potential secret/credential files found:$secret_files" | tee "$artifact_dir/failure.txt"
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. Summary artifact
# ---------------------------------------------------------------------------
cat > "$artifact_dir/summary.json" <<JSON
{
  "gate": "A",
  "status": "pass",
  "timestamp_utc": "$ts_iso",
  "zig_version": "$actual_zig",
  "build": {
    "exit_code": $build_exit,
    "warnings": false
  },
  "tests": {
    "exit_code": $test_exit,
    "passed": ${test_passed:-0},
    "failed": ${test_failed:-0},
    "skipped": ${test_skipped:-0}
  },
  "format": {
    "clean": true
  }
}
JSON

echo "Gate A: PASS"
