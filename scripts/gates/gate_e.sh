#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-e}"
mkdir -p "$artifact_dir"
min_fuzz_cases="${GATE_E_MIN_FUZZ_CASES:-25000}"
max_runtime_s="${GATE_E_MAX_RUNTIME_S:-20}"

# Security-focused suite through build graph (injects build options).
start_ts="$(date +%s)"
zig build gate-e 2>&1 | tee "$artifact_dir/security-gate.log"
end_ts="$(date +%s)"
elapsed_s=$((end_ts - start_ts))

if (( elapsed_s > max_runtime_s )); then
  echo "Gate E runtime exceeded threshold: ${elapsed_s}s > ${max_runtime_s}s" | tee "$artifact_dir/failure.txt"
  exit 1
fi

fuzz_cases="$(rg -o "FUZZ_CASES: [0-9]+" "$artifact_dir/security-gate.log" | awk '{print $2}' | tail -n 1 || true)"
if [[ -z "${fuzz_cases}" ]]; then
  echo "FUZZ_CASES marker missing from security gate output" | tee "$artifact_dir/failure.txt"
  exit 1
fi

if (( fuzz_cases < min_fuzz_cases )); then
  echo "Fuzz budget not met: ${fuzz_cases} < ${min_fuzz_cases}" | tee "$artifact_dir/failure.txt"
  exit 1
fi

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
- gate runtime: ${elapsed_s}s (max ${max_runtime_s}s)
- fuzz cases executed: ${fuzz_cases} (min ${min_fuzz_cases})
- Security test suite executed:
  - src/security_check.zig
MD

cat > "$artifact_dir/fuzz-summary.txt" <<TXT
Fuzzing budget satisfied.
Executed ${fuzz_cases} mutational input-validation cases.
TXT

cat > "$artifact_dir/summary.json" <<JSON
{"gate":"E","status":"pass","panic_sites":$panic_count,"runtime_s":$elapsed_s,"fuzz_cases":$fuzz_cases}
JSON
