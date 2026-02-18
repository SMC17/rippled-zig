#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-c}"
mkdir -p "$artifact_dir"

# Parity-focused suite against captured real XRPL fixtures.
zig test src/parity_gate.zig 2>&1 | tee "$artifact_dir/parity.log"

# Basic fixture contract checks (shape-level parity with rippled responses).
jq -e '.result.info.validated_ledger.seq != null' test_data/server_info.json > /dev/null
jq -e '.result.drops.base_fee != null' test_data/fee_info.json > /dev/null
jq -e '.result.account_data.Account != null' test_data/account_info.json > /dev/null

cat > "$artifact_dir/parity-report.json" <<JSON
{
  "gate": "C",
  "status": "pass",
  "checks": [
    "rpc-shape-suite",
    "fixture-contracts"
  ]
}
JSON
