#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/sim-local}"
mkdir -p "$artifact_dir"

profile="${GATE_SIM_PROFILE:-pr}"
if [[ "$profile" != "pr" && "$profile" != "nightly" ]]; then
  echo "Invalid GATE_SIM_PROFILE: $profile (expected pr|nightly)" >&2
  exit 1
fi

if [[ "$profile" == "nightly" ]]; then
  sim_nodes="${SIM_NODES:-7}"
  sim_rounds="${SIM_ROUNDS:-50}"
  min_success_rate="${GATE_SIM_MIN_SUCCESS_RATE:-35}"
  max_avg_latency_ms="${GATE_SIM_MAX_AVG_LATENCY_MS:-60}"
  min_latest_ledger_seq="${GATE_SIM_MIN_LATEST_LEDGER_SEQ:-1000050}"
else
  sim_nodes="${SIM_NODES:-5}"
  sim_rounds="${SIM_ROUNDS:-20}"
  min_success_rate="${GATE_SIM_MIN_SUCCESS_RATE:-30}"
  max_avg_latency_ms="${GATE_SIM_MAX_AVG_LATENCY_MS:-70}"
  min_latest_ledger_seq="${GATE_SIM_MIN_LATEST_LEDGER_SEQ:-1000020}"
fi

sim_seed="${SIM_SEED:-xrpl-agent-lab-v1}"
sim_base_ledger_seq="${SIM_BASE_LEDGER_SEQ:-1000000}"
sim_base_latency_ms="${SIM_BASE_LATENCY_MS:-40}"
sim_jitter_ms="${SIM_JITTER_MS:-25}"
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

fail() {
  local reason="$1"
  local escaped_reason="${reason//\"/\\\"}"
  echo "$reason" | tee "$artifact_dir/failure.txt"
  cat > "$artifact_dir/sim-gate-report.json" <<JSON
{
  "gate": "SIM",
  "status": "fail",
  "profile": "$profile",
  "timestamp_utc": "$ts_iso",
  "reason": "$escaped_reason"
}
JSON
  exit 1
}

SIM_NODES="$sim_nodes" \
SIM_ROUNDS="$sim_rounds" \
SIM_SEED="$sim_seed" \
SIM_BASE_LEDGER_SEQ="$sim_base_ledger_seq" \
SIM_BASE_LATENCY_MS="$sim_base_latency_ms" \
SIM_JITTER_MS="$sim_jitter_ms" \
scripts/sim/run_local_cluster.sh "$artifact_dir"

summary_file="$artifact_dir/simulation-summary.json"
if [[ ! -f "$summary_file" ]]; then
  fail "Missing simulation summary artifact"
fi

status="$(jq -r '.status // "unknown"' "$summary_file")"
deterministic="$(jq -r '.deterministic // false' "$summary_file")"
nodes="$(jq -r '.cluster.nodes // 0' "$summary_file")"
rounds="$(jq -r '.cluster.rounds // 0' "$summary_file")"
success_rate="$(jq -r '.metrics.success_rate // -1' "$summary_file")"
avg_latency_ms="$(jq -r '.metrics.latency_ms.avg // -1' "$summary_file")"
latest_ledger_seq="$(jq -r '.metrics.latest_ledger_seq // -1' "$summary_file")"

if [[ "$status" != "pass" ]]; then
  fail "Simulation status is not pass: $status"
fi
if [[ "$deterministic" != "true" ]]; then
  fail "Simulation deterministic flag is false"
fi
if ! awk -v got="$nodes" -v min="$sim_nodes" 'BEGIN { exit !(got+0 >= min+0) }'; then
  fail "Simulation nodes below configured minimum: $nodes < $sim_nodes"
fi
if ! awk -v got="$rounds" -v min="$sim_rounds" 'BEGIN { exit !(got+0 >= min+0) }'; then
  fail "Simulation rounds below configured minimum: $rounds < $sim_rounds"
fi
if ! awk -v got="$success_rate" -v min="$min_success_rate" 'BEGIN { exit !(got+0 >= min+0) }'; then
  fail "Simulation success_rate below threshold: $success_rate < $min_success_rate"
fi
if ! awk -v got="$avg_latency_ms" -v max="$max_avg_latency_ms" 'BEGIN { exit !(got+0 <= max+0) }'; then
  fail "Simulation avg latency above threshold: $avg_latency_ms > $max_avg_latency_ms"
fi
if ! awk -v got="$latest_ledger_seq" -v min="$min_latest_ledger_seq" 'BEGIN { exit !(got+0 >= min+0) }'; then
  fail "Simulation latest_ledger_seq below threshold: $latest_ledger_seq < $min_latest_ledger_seq"
fi

cat > "$artifact_dir/sim-thresholds.json" <<JSON
{
  "gate": "SIM",
  "status": "pass",
  "profile": "$profile",
  "timestamp_utc": "$ts_iso",
  "thresholds": {
    "nodes_min": $sim_nodes,
    "rounds_min": $sim_rounds,
    "success_rate_min": $min_success_rate,
    "avg_latency_ms_max": $max_avg_latency_ms,
    "latest_ledger_seq_min": $min_latest_ledger_seq
  },
  "observed": {
    "nodes": $nodes,
    "rounds": $rounds,
    "success_rate": $success_rate,
    "avg_latency_ms": $avg_latency_ms,
    "latest_ledger_seq": $latest_ledger_seq
  }
}
JSON

cp "$artifact_dir/sim-thresholds.json" "$artifact_dir/sim-gate-report.json"
