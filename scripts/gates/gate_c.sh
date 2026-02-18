#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-c}"
mkdir -p "$artifact_dir"
strict_crypto="${GATE_C_STRICT_CRYPTO:-false}"
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Parity-focused suite through build graph (injects build options).
if [[ "$strict_crypto" == "true" ]]; then
  zig build -Dsecp256k1=true gate-c 2>&1 | tee "$artifact_dir/parity.log"
else
  zig build gate-c 2>&1 | tee "$artifact_dir/parity.log"
fi

positive_crypto_vectors="$(grep -c '^CRYPTO_POSITIVE_VECTOR ' "$artifact_dir/parity.log" || true)"
negative_crypto_vectors="$(grep -c '^CRYPTO_NEGATIVE_VECTOR ' "$artifact_dir/parity.log" || true)"
signing_domain_checks="$(grep -c '^SIGNING_DOMAIN_CHECK ' "$artifact_dir/parity.log" || true)"
if (( positive_crypto_vectors < 3 )); then
  echo "Gate C requires >=3 positive secp vectors, got $positive_crypto_vectors" >&2
  exit 1
fi
if (( signing_domain_checks < 3 )); then
  echo "Gate C requires >=3 signing-domain checks, got $signing_domain_checks" >&2
  exit 1
fi
if [[ "$strict_crypto" == "true" ]] && (( negative_crypto_vectors < 3 )); then
  echo "Gate C strict mode requires >=3 negative secp vectors, got $negative_crypto_vectors" >&2
  exit 1
fi

# Basic fixture contract checks (shape-level parity with rippled responses).
jq -e '.result.info.validated_ledger.seq != null' test_data/server_info.json > /dev/null
jq -e '.result.drops.base_fee != null' test_data/fee_info.json > /dev/null
# account_info fixture may be success(account_data) or error(actMalformed) depending on sampled address.
jq -e '(.result.account_data.Account != null) or (.result.error != null and .result.status == "error")' test_data/account_info.json > /dev/null

# Snapshot parity checks: enforce stable fixture values and cross-fixture consistency.
jq -e '.result.info.build_version == "2.6.1-rc2"' test_data/server_info.json > /dev/null
jq -e '.result.info.server_state == "full"' test_data/server_info.json > /dev/null
jq -e '.result.info.network_id == 1' test_data/server_info.json > /dev/null
jq -e '.result.info.peers == 90' test_data/server_info.json > /dev/null
jq -e '.result.info.validated_ledger.seq == 11900686' test_data/server_info.json > /dev/null
jq -e '.result.info.validated_ledger.hash == "FB90529615FA52790E2B2E24C32A482DBF9F969C3FDC2726ED0A64A40962BF00"' test_data/server_info.json > /dev/null

jq -e '.result.status == "success"' test_data/fee_info.json > /dev/null
jq -e '.result.drops.base_fee == "10"' test_data/fee_info.json > /dev/null
jq -e '.result.drops.median_fee == "7500"' test_data/fee_info.json > /dev/null
jq -e '.result.drops.minimum_fee == "10"' test_data/fee_info.json > /dev/null
jq -e '.result.ledger_current_index == 11900687' test_data/fee_info.json > /dev/null

jq -e '.result.status == "error"' test_data/account_info.json > /dev/null
jq -e '.result.error == "actMalformed"' test_data/account_info.json > /dev/null
jq -e '.result.error_code == 35' test_data/account_info.json > /dev/null
jq -e '.result.validated == true' test_data/account_info.json > /dev/null
jq -e '.result.ledger_index == 11900686' test_data/account_info.json > /dev/null
jq -e '.result.ledger_hash == "FB90529615FA52790E2B2E24C32A482DBF9F969C3FDC2726ED0A64A40962BF00"' test_data/account_info.json > /dev/null

jq -e '.result.status == "success"' test_data/current_ledger.json > /dev/null
jq -e '(.result.ledger.ledger_index | tostring) == "11900686"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.ledger_hash == "FB90529615FA52790E2B2E24C32A482DBF9F969C3FDC2726ED0A64A40962BF00"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.closed == true' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].hash == "09D0D3C0AB0E6D8EBB3117C2FF1DD72F063818F528AF54A4553C8541DD2E8B5B"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].SigningPubKey == "02D3FC6F04117E6420CAEA735C57CEEC934820BBCD109200933F6BBDD98F7BFBD9"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].TxnSignature == "3045022100E30FEACFAE9ED8034C4E24203BBFD6CE0D48ABCA901EDCE6EE04AA281A4DD73F02200CA7FDF03DC0B56F6E6FC5B499B4830F1ABD6A57FC4BE5C03F2CAF3CAFD1FF85"' test_data/current_ledger.json > /dev/null

# Cross-fixture consistency assertions.
server_seq="$(jq -r '.result.info.validated_ledger.seq' test_data/server_info.json)"
server_hash="$(jq -r '.result.info.validated_ledger.hash' test_data/server_info.json)"
ledger_seq="$(jq -r '.result.ledger.ledger_index | tostring' test_data/current_ledger.json)"
ledger_hash="$(jq -r '.result.ledger.ledger_hash' test_data/current_ledger.json)"
acct_seq="$(jq -r '.result.ledger_index' test_data/account_info.json)"
acct_hash="$(jq -r '.result.ledger_hash' test_data/account_info.json)"
if [[ "$server_seq" != "$ledger_seq" || "$server_seq" != "$acct_seq" ]]; then
  echo "Fixture sequence mismatch across server/account/ledger snapshots" >&2
  exit 1
fi
if [[ "$server_hash" != "$ledger_hash" || "$server_hash" != "$acct_hash" ]]; then
  echo "Fixture hash mismatch across server/account/ledger snapshots" >&2
  exit 1
fi

cat > "$artifact_dir/parity-report.json" <<JSON
{
  "gate": "C",
  "status": "pass",
  "timestamp_utc": "$ts_iso",
  "strict_crypto": "$strict_crypto",
  "crypto_vectors": {
    "positive": $positive_crypto_vectors,
    "negative": $negative_crypto_vectors,
    "signing_domain": $signing_domain_checks
  },
  "checks": [
    "rpc-shape-suite",
    "fixture-contracts",
    "snapshot-field-values",
    "snapshot-validated-ledger-seq-hash",
    "cross-fixture-consistency",
    "secp-fixture-signature-values",
    "negative-crypto-controls",
    "strict-secp-vector-set-and-negative-controls",
    "signing-domain-guardrails"
  ]
}
JSON

if [[ -n "${GATE_C_TREND_INPUT_DIR:-}" ]]; then
  bash scripts/gates/gate_c_trend_merge.sh \
    "$GATE_C_TREND_INPUT_DIR" \
    "$artifact_dir/crypto-trend-summary-7d.json" \
    "${GATE_C_TREND_MAX_POINTS:-200}"

  trend_status="$(jq -r '.status // "unknown"' "$artifact_dir/crypto-trend-summary-7d.json")"
  if [[ "$trend_status" == "ok" ]]; then
    trend_min_success_rate="${GATE_C_TREND_MIN_SUCCESS_RATE:-99}"
    trend_min_avg_pos="${GATE_C_TREND_MIN_AVG_POSITIVE_VECTORS:-3}"
    trend_min_avg_signing="${GATE_C_TREND_MIN_AVG_SIGNING_DOMAIN_CHECKS:-3}"
    trend_min_consecutive_strict_passes="${GATE_C_TREND_MIN_CONSEC_STRICT_PASSES:-0}"
    trend_fail_on_insufficient="${GATE_C_FAIL_ON_INSUFFICIENT_TREND:-false}"

    success_rate="$(jq -r '.summary.success_rate' "$artifact_dir/crypto-trend-summary-7d.json")"
    avg_pos="$(jq -r '.summary.avg_positive_vectors' "$artifact_dir/crypto-trend-summary-7d.json")"
    avg_signing="$(jq -r '.summary.avg_signing_domain_checks' "$artifact_dir/crypto-trend-summary-7d.json")"
    cons_strict="$(jq -r '.summary.consecutive_strict_passes_from_latest' "$artifact_dir/crypto-trend-summary-7d.json")"
    strict_runs="$(jq -r '.summary.strict_runs' "$artifact_dir/crypto-trend-summary-7d.json")"

    if ! awk -v got="$success_rate" -v min="$trend_min_success_rate" 'BEGIN { exit !(got+0 >= min+0) }'; then
      echo "Gate C trend success_rate below threshold: ${success_rate}% < ${trend_min_success_rate}%" >&2
      exit 1
    fi
    if ! awk -v got="$avg_pos" -v min="$trend_min_avg_pos" 'BEGIN { exit !(got+0 >= min+0) }'; then
      echo "Gate C trend avg positive vectors below threshold: ${avg_pos} < ${trend_min_avg_pos}" >&2
      exit 1
    fi
    if ! awk -v got="$avg_signing" -v min="$trend_min_avg_signing" 'BEGIN { exit !(got+0 >= min+0) }'; then
      echo "Gate C trend avg signing-domain checks below threshold: ${avg_signing} < ${trend_min_avg_signing}" >&2
      exit 1
    fi
    if (( trend_min_consecutive_strict_passes > 0 )); then
      if [[ "$strict_runs" == "0" && "$trend_fail_on_insufficient" == "true" ]]; then
        echo "Gate C trend has no strict runs, cannot satisfy strict streak requirement" >&2
        exit 1
      fi
      if ! awk -v got="$cons_strict" -v min="$trend_min_consecutive_strict_passes" 'BEGIN { exit !(got+0 >= min+0) }'; then
        echo "Gate C trend strict consecutive passes below threshold: ${cons_strict} < ${trend_min_consecutive_strict_passes}" >&2
        exit 1
      fi
    fi
  fi
fi
