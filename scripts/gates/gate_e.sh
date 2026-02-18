#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-e}"
mkdir -p "$artifact_dir"

# Security-focused suite through build graph (injects build options).
zig build gate-e 2>&1 | tee "$artifact_dir/security-gate.log"

# Static hygiene checks.
if rg -n "@setRuntimeSafety\(false\)" src tests > "$artifact_dir/runtime-safety-violations.txt"; then
  echo "Runtime safety disabled in tracked code" | tee "$artifact_dir/failure.txt"
  exit 1
fi

if rg -n "\bpanic\(" src > "$artifact_dir/panic-usage.txt"; then
  panic_count=$(wc -l < "$artifact_dir/panic-usage.txt" | tr -d ' ')
else
  panic_count=0
fi

if rg -n "TODO|FIXME" src/security.zig src/security_check.zig > "$artifact_dir/security-todo-findings.txt"; then
  echo "Security-critical TODO/FIXME markers found" | tee "$artifact_dir/failure.txt"
  exit 1
fi

if (( panic_count > 0 )); then
  echo "panic() usage found in src; disallowed for Gate E hardening" | tee "$artifact_dir/failure.txt"
  exit 1
fi

# Generate security review artifact from actual scans/tests.
cat > "$artifact_dir/security-review.md" <<MD
# Gate E Security Review

- Runtime safety disabled sites: 0
- panic() call sites in src: $panic_count
- security TODO/FIXME findings in `src/security*.zig`: 0
- Security test suite executed:
  - src/security_check.zig
MD

cat > "$artifact_dir/fuzz-summary.txt" <<TXT
Fuzzing baseline: parser and boundary safety validated through edge-case suites.
Next expansion path: dedicated mutational fuzz harness over protocol/frame parsers.
TXT

cat > "$artifact_dir/summary.json" <<JSON
{"gate":"E","status":"pass","panic_sites":$panic_count}
JSON
