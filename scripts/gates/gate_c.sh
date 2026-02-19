#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-c}"
mkdir -p "$artifact_dir"
strict_crypto="${GATE_C_STRICT_CRYPTO:-false}"
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    echo "No SHA256 tool found (need shasum or sha256sum)" >&2
    exit 1
  fi
}

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

# secp vector provenance and fixture SHA pin checks.
provenance_json="test_data/secp_vector_provenance.json"
provenance_pin_file="test_data/secp_vector_provenance.sha256"
fixture_manifest="test_data/fixture_manifest.sha256"
if [[ ! -f "$provenance_json" || ! -f "$provenance_pin_file" ]]; then
  echo "Missing secp provenance files: $provenance_json and/or $provenance_pin_file" >&2
  exit 1
fi
if [[ ! -f "$fixture_manifest" ]]; then
  echo "Missing fixture manifest: $fixture_manifest" >&2
  exit 1
fi

expected_provenance_sha="$(awk '{print $1}' "$provenance_pin_file")"
actual_provenance_sha="$(sha256_file "$provenance_json")"
if [[ "$expected_provenance_sha" != "$actual_provenance_sha" ]]; then
  echo "Secp provenance SHA pin mismatch: expected $expected_provenance_sha got $actual_provenance_sha" >&2
  exit 1
fi

fixture_path="$(jq -r '.source_fixture.path' "$provenance_json")"
fixture_sha_pinned="$(jq -r '.source_fixture.sha256' "$provenance_json")"
if [[ "$fixture_path" == "null" || "$fixture_sha_pinned" == "null" ]]; then
  echo "Secp provenance missing source_fixture.path or source_fixture.sha256" >&2
  exit 1
fi
if [[ ! -f "$fixture_path" ]]; then
  echo "Secp source fixture path missing: $fixture_path" >&2
  exit 1
fi
actual_fixture_sha="$(sha256_file "$fixture_path")"
if [[ "$actual_fixture_sha" != "$fixture_sha_pinned" ]]; then
  echo "Fixture SHA mismatch for $fixture_path: pinned $fixture_sha_pinned got $actual_fixture_sha" >&2
  exit 1
fi
manifest_fixture_sha="$(awk -v p="$fixture_path" '$2==p {print $1}' "$fixture_manifest")"
if [[ -z "$manifest_fixture_sha" ]]; then
  echo "Fixture path $fixture_path not found in $fixture_manifest" >&2
  exit 1
fi
if [[ "$manifest_fixture_sha" != "$fixture_sha_pinned" ]]; then
  echo "Fixture SHA pin mismatch vs manifest for $fixture_path: provenance $fixture_sha_pinned manifest $manifest_fixture_sha" >&2
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
jq -e '.result.ledger.account_hash == "A569ACFF4EB95A65B8FD3A9A7C0E68EE17A96EA051896A3F235863ED776ACBAE"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.parent_hash == "630D7DDAFBCF0449FEC7E4EB4056F2187BDCC6C4315788D6416766A4B7C7F6B6"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transaction_hash == "FAA3C9DB987A612C9A4B011805F00BF69DA56E8DF127D9AACB7C13A1CD0BC505"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.total_coins == "99999914350172385"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.close_time == 815078240' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.parent_close_time == 815078232' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.close_time_resolution == 10' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.close_flags == 0' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.closed == true' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions | length == 6' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].Account == "rPickFLAKK7YkMwKvhSEN1yJAtfnB6qRJc"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].TransactionType == "SignerListSet"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].Fee == "7500"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].Sequence == 11900682' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].hash == "09D0D3C0AB0E6D8EBB3117C2FF1DD72F063818F528AF54A4553C8541DD2E8B5B"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].SigningPubKey == "02D3FC6F04117E6420CAEA735C57CEEC934820BBCD109200933F6BBDD98F7BFBD9"' test_data/current_ledger.json > /dev/null
jq -e '.result.ledger.transactions[0].TxnSignature == "3045022100E30FEACFAE9ED8034C4E24203BBFD6CE0D48ABCA901EDCE6EE04AA281A4DD73F02200CA7FDF03DC0B56F6E6FC5B499B4830F1ABD6A57FC4BE5C03F2CAF3CAFD1FF85"' test_data/current_ledger.json > /dev/null

# Deterministic offline schema fixture check for agent_status contract.
jq -e '.schema_version == 1' test_data/agent_status_schema.json > /dev/null
jq -e '.rpc_method == "agent_status"' test_data/agent_status_schema.json > /dev/null
jq -e '.required_fields.result == ["status","agent_control","node_state"]' test_data/agent_status_schema.json > /dev/null
jq -e '.required_fields.agent_control == ["api_version","mode","strict_crypto_required"]' test_data/agent_status_schema.json > /dev/null
jq -e '.required_fields.node_state == ["uptime","validated_ledger_seq","pending_transactions","max_peers","allow_unl_updates"]' test_data/agent_status_schema.json > /dev/null
jq -e '.expected_values.status == "success"' test_data/agent_status_schema.json > /dev/null
jq -e '.expected_values.api_version == 1' test_data/agent_status_schema.json > /dev/null
jq -e '.expected_values.mode == "research"' test_data/agent_status_schema.json > /dev/null
jq -e '.expected_values.strict_crypto_required == true' test_data/agent_status_schema.json > /dev/null
jq -e '.expected_values.max_peers == 21' test_data/agent_status_schema.json > /dev/null
jq -e '.expected_values.allow_unl_updates == false' test_data/agent_status_schema.json > /dev/null

# Deterministic offline schema fixture check for agent_config_get contract.
jq -e '.schema_version == 1' test_data/agent_config_schema.json > /dev/null
jq -e '.rpc_method == "agent_config_get"' test_data/agent_config_schema.json > /dev/null
jq -e '.required_fields.result == ["status","config"]' test_data/agent_config_schema.json > /dev/null
jq -e '.required_fields.config == ["profile","max_peers","fee_multiplier","strict_crypto_required","allow_unl_updates"]' test_data/agent_config_schema.json > /dev/null
jq -e '.expected_values.status == "success"' test_data/agent_config_schema.json > /dev/null
jq -e '.expected_values.profile == "research"' test_data/agent_config_schema.json > /dev/null
jq -e '.expected_values.max_peers == 21' test_data/agent_config_schema.json > /dev/null
jq -e '.expected_values.fee_multiplier == 1' test_data/agent_config_schema.json > /dev/null
jq -e '.expected_values.strict_crypto_required == true' test_data/agent_config_schema.json > /dev/null
jq -e '.expected_values.allow_unl_updates == false' test_data/agent_config_schema.json > /dev/null

# Deterministic offline schema fixture checks for newly live JSON-RPC methods.
jq -e '.schema_version == 1' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.account_info.required_result_fields == ["account_data","ledger_current_index","status","validated"]' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.account_info.required_account_data_fields == ["Account","Balance","Flags","OwnerCount","Sequence"]' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.account_info.expected_status == "success"' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.account_info.expected_validated == true' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.submit.required_result_fields == ["engine_result","engine_result_code","status","validated","tx_json"]' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.submit.expected_status == "success"' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.submit.expected_engine_result == "tesSUCCESS"' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.ping.required_fields == ["result"]' test_data/rpc_live_methods_schema.json > /dev/null
jq -e '.methods.ledger_current.required_result_fields == ["ledger_current_index"]' test_data/rpc_live_methods_schema.json > /dev/null

# Deterministic offline schema fixture checks for negative live JSON-RPC contracts.
jq -e '.schema_version == 1' test_data/rpc_live_negative_schema.json > /dev/null
jq -e '.cases.account_info_missing_param.expected_error == "Invalid account_info params"' test_data/rpc_live_negative_schema.json > /dev/null
jq -e '.cases.account_info_invalid_account.expected_error == "Invalid account_info params"' test_data/rpc_live_negative_schema.json > /dev/null
jq -e '.cases.submit_missing_blob.expected_error == "Invalid submit params"' test_data/rpc_live_negative_schema.json > /dev/null
jq -e '.cases.submit_empty_blob.expected_error == "Invalid submit params"' test_data/rpc_live_negative_schema.json > /dev/null
jq -e '.cases.submit_blocked_in_production.expected_error == "Method blocked by profile policy"' test_data/rpc_live_negative_schema.json > /dev/null

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
    "secp-provenance-sha-pin",
    "secp-fixture-sha-pin",
    "snapshot-field-values",
    "snapshot-ledger-value-level-fields",
    "agent-status-schema-stability",
    "agent-config-schema-stability",
    "rpc-live-method-schema-stability",
    "rpc-live-negative-schema-stability",
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
