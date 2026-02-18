#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-c}"
mkdir -p "$artifact_dir"

# Parity-focused suite through build graph (injects build options).
zig build gate-c 2>&1 | tee "$artifact_dir/parity.log"

# Basic fixture contract checks (shape-level parity with rippled responses).
jq -e '.result.info.validated_ledger.seq != null' test_data/server_info.json > /dev/null
jq -e '.result.drops.base_fee != null' test_data/fee_info.json > /dev/null
# account_info fixture may be success(account_data) or error(actMalformed) depending on sampled address.
jq -e '(.result.account_data.Account != null) or (.result.error != null and .result.status == "error")' test_data/account_info.json > /dev/null

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
