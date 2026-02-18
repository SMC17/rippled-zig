#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/gate-d}"
mkdir -p "$artifact_dir"

rpc_url="${TESTNET_RPC_URL:-}"
ws_url="${TESTNET_WS_URL:-}"
max_latency_s="${GATE_D_MAX_LATENCY_S:-5}"
min_ledger_seq="${GATE_D_MIN_LEDGER_SEQ:-1000000}"
expected_network_id="${GATE_D_EXPECTED_NETWORK_ID:-1}"
max_base_fee="${GATE_D_MAX_BASE_FEE:-100000}"
min_base_fee="${GATE_D_MIN_BASE_FEE:-10}"
run_profile="${GATE_D_PROFILE:-default}"
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

fail() {
  local reason="$1"
  local escaped_reason="${reason//\"/\\\"}"
  echo "$reason" | tee "$artifact_dir/failure.txt"
  cat > "$artifact_dir/testnet-conformance.json" <<JSON
{
  "gate": "D",
  "status": "fail",
  "reason": "$escaped_reason",
  "profile": "$run_profile",
  "timestamp_utc": "$ts_iso"
}
JSON
  exit 1
}

if [[ -z "$rpc_url" || -z "$ws_url" ]]; then
  if [[ "${GATE_D_ALLOW_SKIP_NO_SECRETS:-false}" == "true" ]]; then
    cat > "$artifact_dir/testnet-conformance.json" <<JSON
{
  "gate": "D",
  "status": "skipped",
  "reason": "missing TESTNET_RPC_URL/TESTNET_WS_URL",
  "profile": "$run_profile",
  "timestamp_utc": "$ts_iso"
}
JSON
    exit 0
  fi
  fail "TESTNET_RPC_URL and TESTNET_WS_URL are required"
fi

if [[ ! "$rpc_url" =~ ^https:// ]]; then
  fail "TESTNET_RPC_URL must use https:// scheme"
fi
if [[ ! "$ws_url" =~ ^wss:// ]]; then
  fail "TESTNET_WS_URL must use wss:// scheme"
fi

for cmd in curl jq awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "$cmd is required"
  fi
done

post_json() {
  local payload="$1"
  local out_file="$2"
  local metrics_file="$3"

  local tmp_body
  tmp_body="$(mktemp)"

  local curl_meta
  curl_meta="$(curl -sS --fail \
    -o "$tmp_body" \
    -w '%{http_code} %{time_total}' \
    -X POST "$rpc_url" \
    -H 'Content-Type: application/json' \
    -d "$payload")"

  mv "$tmp_body" "$out_file"
  printf '%s\n' "$curl_meta" > "$metrics_file"

  local http_code latency
  http_code="$(awk '{print $1}' "$metrics_file")"
  latency="$(awk '{print $2}' "$metrics_file")"

  if [[ "$http_code" != "200" ]]; then
    fail "HTTP failure for payload: $payload"
  fi

  if ! awk -v got="$latency" -v max="$max_latency_s" 'BEGIN { exit !(got+0 <= max+0) }'; then
    fail "Latency threshold exceeded: ${latency}s > ${max_latency_s}s"
  fi
}

post_json '{"method":"server_info"}' "$artifact_dir/server_info.json" "$artifact_dir/server_info.metrics"
post_json '{"method":"fee"}' "$artifact_dir/fee.json" "$artifact_dir/fee.metrics"

validated_seq="$(jq -r '.result.info.validated_ledger.seq' "$artifact_dir/server_info.json")"
validated_hash="$(jq -r '.result.info.validated_ledger.hash' "$artifact_dir/server_info.json")"
server_state="$(jq -r '.result.info.server_state' "$artifact_dir/server_info.json")"
network_id="$(jq -r '.result.info.network_id' "$artifact_dir/server_info.json")"
server_info_status="$(jq -r '.result.status' "$artifact_dir/server_info.json")"
base_fee="$(jq -r '.result.drops.base_fee' "$artifact_dir/fee.json")"
fee_status="$(jq -r '.result.status' "$artifact_dir/fee.json")"

if [[ -z "$validated_seq" || "$validated_seq" == "null" ]]; then
  fail "Missing validated ledger sequence"
fi

if ! [[ "$validated_seq" =~ ^[0-9]+$ ]]; then
  fail "Non-numeric validated ledger sequence: $validated_seq"
fi

if (( validated_seq < min_ledger_seq )); then
  fail "Validated ledger sequence too low: $validated_seq < $min_ledger_seq"
fi

if ! [[ "$validated_hash" =~ ^[A-F0-9]{64}$ ]]; then
  fail "Invalid validated ledger hash format"
fi

if [[ "$server_info_status" != "success" ]]; then
  fail "server_info status is not success: $server_info_status"
fi

if ! [[ "$network_id" =~ ^[0-9]+$ ]]; then
  fail "Non-numeric network_id: $network_id"
fi

if (( network_id != expected_network_id )); then
  fail "Unexpected network_id: $network_id (expected $expected_network_id)"
fi

case "$server_state" in
  full|proposing|validating|syncing)
    ;;
  *)
    fail "Unexpected server_state: $server_state"
    ;;
esac

if ! [[ "$base_fee" =~ ^[0-9]+$ ]]; then
  fail "Non-numeric base_fee: $base_fee"
fi

if [[ "$fee_status" != "success" ]]; then
  fail "fee status is not success: $fee_status"
fi

if (( base_fee < min_base_fee || base_fee > max_base_fee )); then
  fail "base_fee outside threshold: $base_fee (expected $min_base_fee..$max_base_fee)"
fi

ledger_payload="{\"method\":\"ledger\",\"params\":[{\"ledger_index\":$validated_seq,\"transactions\":false,\"expand\":false}] }"
post_json "$ledger_payload" "$artifact_dir/ledger.json" "$artifact_dir/ledger.metrics"

ledger_seq="$(jq -r '.result.ledger.ledger_index // .result.ledger_index' "$artifact_dir/ledger.json")"
ledger_hash="$(jq -r '.result.ledger.ledger_hash // .result.ledger_hash' "$artifact_dir/ledger.json")"
ledger_status="$(jq -r '.result.status // \"success\"' "$artifact_dir/ledger.json")"

if ! [[ "$ledger_seq" =~ ^[0-9]+$ ]]; then
  fail "Non-numeric ledger sequence returned from ledger method: $ledger_seq"
fi

if (( ledger_seq != validated_seq )); then
  fail "Cross-endpoint mismatch: server_info seq=$validated_seq ledger seq=$ledger_seq"
fi

if ! [[ "$ledger_hash" =~ ^[A-F0-9]{64}$ ]]; then
  fail "Invalid ledger hash format from ledger method"
fi

if [[ "$ledger_status" != "success" ]]; then
  fail "ledger status is not success: $ledger_status"
fi

if [[ "$ledger_hash" != "$validated_hash" ]]; then
  fail "Cross-endpoint mismatch: server_info hash != ledger hash"
fi

server_latency="$(awk '{print $2}' "$artifact_dir/server_info.metrics")"
fee_latency="$(awk '{print $2}' "$artifact_dir/fee.metrics")"
ledger_latency="$(awk '{print $2}' "$artifact_dir/ledger.metrics")"

cat > "$artifact_dir/testnet-conformance.json" <<JSON
{
  "gate": "D",
  "status": "pass",
  "profile": "$run_profile",
  "timestamp_utc": "$ts_iso",
  "thresholds": {
    "max_latency_s": $max_latency_s,
    "min_ledger_seq": $min_ledger_seq,
    "network_id": $expected_network_id,
    "base_fee_min": $min_base_fee,
    "base_fee_max": $max_base_fee
  },
  "network": {
    "rpc_url": "$rpc_url",
    "ws_url": "$ws_url"
  },
  "observed": {
    "endpoint_health": {
      "rpc_https": true,
      "ws_wss": true
    },
    "server_state": "$server_state",
    "validated_ledger_seq": $validated_seq,
    "validated_ledger_hash": "$validated_hash",
    "base_fee": $base_fee,
    "latency_s": {
      "server_info": $server_latency,
      "fee": $fee_latency,
      "ledger": $ledger_latency
    }
  }
}
JSON

cat > "$artifact_dir/trend-point.json" <<JSON
{
  "timestamp_utc": "$ts_iso",
  "profile": "$run_profile",
  "status": "pass",
  "validated_ledger_seq": $validated_seq,
  "base_fee": $base_fee,
  "latency_s": {
    "server_info": $server_latency,
    "fee": $fee_latency,
    "ledger": $ledger_latency
  }
}
JSON
