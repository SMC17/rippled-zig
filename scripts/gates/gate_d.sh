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
account_info_fixture_file="${GATE_D_ACCOUNT_INFO_FIXTURE:-test_data/gate_d_account_info_fixture.json}"
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

if [[ ! -f "$account_info_fixture_file" ]]; then
  fail "Missing Gate D account_info fixture: $account_info_fixture_file"
fi
if ! jq -e '.schema_version == 1 and (.account | type == "string") and (.required_account_data_fields | type == "array")' "$account_info_fixture_file" >/dev/null; then
  fail "Invalid Gate D account_info fixture schema: $account_info_fixture_file"
fi

account_info_positive_account="$(jq -r '.account' "$account_info_fixture_file")"
if [[ -z "$account_info_positive_account" || "$account_info_positive_account" == "null" ]]; then
  fail "Gate D account_info fixture missing account value"
fi

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
post_json '{"method":"ping"}' "$artifact_dir/ping.json" "$artifact_dir/ping.metrics"
post_json '{"method":"ledger_current"}' "$artifact_dir/ledger_current.json" "$artifact_dir/ledger_current.metrics"
account_info_positive_payload="$(jq -nc --arg acct "$account_info_positive_account" '{method:"account_info", params:[{account:$acct}]}' )"
post_json "$account_info_positive_payload" "$artifact_dir/account_info_positive.json" "$artifact_dir/account_info_positive.metrics"
post_json '{"method":"account_info","params":[{"account":"invalid"}]}' "$artifact_dir/account_info_negative.json" "$artifact_dir/account_info_negative.metrics"
post_json '{"method":"submit","params":[{}]}' "$artifact_dir/submit_negative.json" "$artifact_dir/submit_negative.metrics"

validated_seq="$(jq -r '.result.info.validated_ledger.seq' "$artifact_dir/server_info.json")"
validated_hash="$(jq -r '.result.info.validated_ledger.hash' "$artifact_dir/server_info.json")"
server_state="$(jq -r '.result.info.server_state' "$artifact_dir/server_info.json")"
network_id="$(jq -r '.result.info.network_id' "$artifact_dir/server_info.json")"
server_info_status="$(jq -r '.result.status' "$artifact_dir/server_info.json")"
base_fee="$(jq -r '.result.drops.base_fee' "$artifact_dir/fee.json")"
fee_status="$(jq -r '.result.status' "$artifact_dir/fee.json")"
ping_status="$(jq -r '.result.status // .status // "unknown"' "$artifact_dir/ping.json")"
ping_role="$(jq -r '.result.role // empty' "$artifact_dir/ping.json")"
ledger_current_status="$(jq -r '.result.status // .status // "unknown"' "$artifact_dir/ledger_current.json")"
ledger_current_index="$(jq -r '.result.ledger_current_index // empty' "$artifact_dir/ledger_current.json")"
account_info_pos_status="$(jq -r '.result.status // .status // "unknown"' "$artifact_dir/account_info_positive.json")"
account_info_neg_status="$(jq -r '.result.status // .status // "unknown"' "$artifact_dir/account_info_negative.json")"
account_info_neg_error="$(jq -r '.result.error // .error // empty' "$artifact_dir/account_info_negative.json")"
submit_neg_status="$(jq -r '.result.status // .status // "unknown"' "$artifact_dir/submit_negative.json")"
submit_neg_error="$(jq -r '.result.error // .error // empty' "$artifact_dir/submit_negative.json")"

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
if [[ "$ping_status" != "success" ]]; then
  fail "ping status is not success: $ping_status"
fi
if [[ -n "$ping_role" && "$ping_role" != "null" ]]; then
  case "$ping_role" in
    admin|user|guest|proxy)
      ;;
    *)
      fail "Unexpected ping role: $ping_role"
      ;;
  esac
fi
if [[ "$ledger_current_status" != "success" ]]; then
  fail "ledger_current status is not success: $ledger_current_status"
fi
if ! [[ "$ledger_current_index" =~ ^[0-9]+$ ]]; then
  fail "Non-numeric ledger_current_index: $ledger_current_index"
fi
if (( ledger_current_index < validated_seq )); then
  fail "ledger_current_index behind validated_seq: $ledger_current_index < $validated_seq"
fi

if [[ "$account_info_pos_status" != "success" ]]; then
  fail "account_info positive contract expected status=success, got: $account_info_pos_status"
fi
if ! jq -e '.result.account_data.Account != null and .result.account_data.Balance != null and .result.account_data.Sequence != null' "$artifact_dir/account_info_positive.json" >/dev/null; then
  fail "account_info positive contract missing required account_data fields"
fi

if (( base_fee < min_base_fee || base_fee > max_base_fee )); then
  fail "base_fee outside threshold: $base_fee (expected $min_base_fee..$max_base_fee)"
fi

if [[ "$account_info_neg_status" != "error" ]]; then
  fail "account_info negative contract expected status=error, got: $account_info_neg_status"
fi
if [[ -z "$account_info_neg_error" || "$account_info_neg_error" == "null" ]]; then
  fail "account_info negative contract missing error field"
fi

if [[ "$submit_neg_status" != "error" ]]; then
  fail "submit negative contract expected status=error, got: $submit_neg_status"
fi
if [[ -z "$submit_neg_error" || "$submit_neg_error" == "null" ]]; then
  fail "submit negative contract missing error field"
fi

ledger_payload="{\"method\":\"ledger\",\"params\":[{\"ledger_index\":$validated_seq,\"transactions\":false,\"expand\":false}] }"
post_json "$ledger_payload" "$artifact_dir/ledger.json" "$artifact_dir/ledger.metrics"

ledger_seq="$(jq -r '.result.ledger.ledger_index // .result.ledger_index' "$artifact_dir/ledger.json")"
ledger_hash="$(jq -r '.result.ledger.ledger_hash // .result.ledger_hash' "$artifact_dir/ledger.json")"
ledger_status="$(jq -r '.result.status // "success"' "$artifact_dir/ledger.json")"

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
ping_latency="$(awk '{print $2}' "$artifact_dir/ping.metrics")"
ledger_current_latency="$(awk '{print $2}' "$artifact_dir/ledger_current.metrics")"
ledger_latency="$(awk '{print $2}' "$artifact_dir/ledger.metrics")"
account_info_positive_latency="$(awk '{print $2}' "$artifact_dir/account_info_positive.metrics")"
account_info_negative_latency="$(awk '{print $2}' "$artifact_dir/account_info_negative.metrics")"
submit_negative_latency="$(awk '{print $2}' "$artifact_dir/submit_negative.metrics")"

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
    "ledger_current_index": $ledger_current_index,
    "base_fee": $base_fee,
    "method_status": {
      "server_info": "$server_info_status",
      "fee": "$fee_status",
      "ping": "$ping_status",
      "ledger_current": "$ledger_current_status",
      "account_info_positive": "$account_info_pos_status",
      "ledger": "$ledger_status"
    },
    "negative_contracts": {
      "account_info_status": "$account_info_neg_status",
      "account_info_error": "$account_info_neg_error",
      "submit_status": "$submit_neg_status",
      "submit_error": "$submit_neg_error"
    },
    "latency_s": {
      "server_info": $server_latency,
      "fee": $fee_latency,
      "ping": $ping_latency,
      "ledger_current": $ledger_current_latency,
      "ledger": $ledger_latency,
      "account_info_positive": $account_info_positive_latency,
      "account_info_negative": $account_info_negative_latency,
      "submit_negative": $submit_negative_latency
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
  "ledger_current_index": $ledger_current_index,
  "base_fee": $base_fee,
  "method_status": {
    "ping": "$ping_status",
    "ledger_current": "$ledger_current_status",
    "account_info_positive": "$account_info_pos_status"
  },
  "latency_s": {
    "server_info": $server_latency,
    "fee": $fee_latency,
    "ping": $ping_latency,
    "ledger_current": $ledger_current_latency,
    "ledger": $ledger_latency,
    "account_info_positive": $account_info_positive_latency,
    "account_info_negative": $account_info_negative_latency,
    "submit_negative": $submit_negative_latency
  }
}
JSON

if [[ -n "${GATE_D_TREND_INPUT_DIR:-}" ]]; then
  scripts/gates/gate_d_trend_merge.sh \
    "$GATE_D_TREND_INPUT_DIR" \
    "$artifact_dir/trend-summary-7d.json" \
    "${GATE_D_TREND_MAX_POINTS:-200}"

  trend_min_success_rate="${GATE_D_TREND_MIN_SUCCESS_RATE:-99}"
  trend_max_p95_server_info="${GATE_D_TREND_MAX_P95_SERVER_INFO_S:-$max_latency_s}"
  trend_max_p95_fee="${GATE_D_TREND_MAX_P95_FEE_S:-$max_latency_s}"
  trend_max_p95_ledger="${GATE_D_TREND_MAX_P95_LEDGER_S:-$max_latency_s}"

  trend_status="$(jq -r '.status // "unknown"' "$artifact_dir/trend-summary-7d.json")"
  if [[ "$trend_status" == "ok" ]]; then
    success_rate="$(jq -r '.summary.success_rate' "$artifact_dir/trend-summary-7d.json")"
    p95_server_info="$(jq -r '.summary.p95_latency_s.server_info' "$artifact_dir/trend-summary-7d.json")"
    p95_fee="$(jq -r '.summary.p95_latency_s.fee' "$artifact_dir/trend-summary-7d.json")"
    p95_ledger="$(jq -r '.summary.p95_latency_s.ledger' "$artifact_dir/trend-summary-7d.json")"

    if ! awk -v got="$success_rate" -v min="$trend_min_success_rate" 'BEGIN { exit !(got+0 >= min+0) }'; then
      fail "Gate D trend success_rate below threshold: ${success_rate}% < ${trend_min_success_rate}%"
    fi
    if ! awk -v got="$p95_server_info" -v max="$trend_max_p95_server_info" 'BEGIN { exit !(got+0 <= max+0) }'; then
      fail "Gate D trend p95 server_info latency above threshold: ${p95_server_info}s > ${trend_max_p95_server_info}s"
    fi
    if ! awk -v got="$p95_fee" -v max="$trend_max_p95_fee" 'BEGIN { exit !(got+0 <= max+0) }'; then
      fail "Gate D trend p95 fee latency above threshold: ${p95_fee}s > ${trend_max_p95_fee}s"
    fi
    if ! awk -v got="$p95_ledger" -v max="$trend_max_p95_ledger" 'BEGIN { exit !(got+0 <= max+0) }'; then
      fail "Gate D trend p95 ledger latency above threshold: ${p95_ledger}s > ${trend_max_p95_ledger}s"
    fi
  fi
fi
