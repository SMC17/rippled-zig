#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/sim-queue-pressure}"
mkdir -p "$artifact_dir"

nodes="${SIM_NODES:-5}"
rounds="${SIM_ROUNDS:-20}"
seed="${SIM_SEED:-xrpl-agent-queue-pressure-v1}"
base_ledger_seq="${SIM_BASE_LEDGER_SEQ:-1000000}"

tx_burst_size="${SIM_QP_TX_BURST_SIZE:-100}"
queue_capacity="${SIM_QP_QUEUE_CAPACITY:-180}"
drain_rate_per_round="${SIM_QP_DRAIN_RATE_PER_ROUND:-130}"
base_latency_ms="${SIM_QP_BASE_LATENCY_MS:-45}"
jitter_ms="${SIM_QP_JITTER_MS:-20}"
retry_penalty_ms="${SIM_QP_RETRY_PENALTY_MS:-12}"

envelope_max_drop_rate="${SIM_QP_ENVELOPE_MAX_DROP_RATE:-45}"
envelope_max_avg_latency_ms="${SIM_QP_ENVELOPE_MAX_AVG_LATENCY_MS:-95}"
envelope_max_peak_queue="${SIM_QP_ENVELOPE_MAX_PEAK_QUEUE:-140}"

if (( nodes <= 0 || rounds <= 0 )); then
  echo "SIM_NODES and SIM_ROUNDS must be > 0" >&2
  exit 1
fi
if (( tx_burst_size <= 0 || queue_capacity <= 0 || drain_rate_per_round <= 0 )); then
  echo "Queue-pressure scenario parameters must be > 0" >&2
  exit 1
fi

hash_hex() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf "%s" "$input" | shasum -a 256 | awk '{print $1}'
  else
    printf "%s" "$input" | sha256sum | awk '{print $1}'
  fi
}

hex_to_dec8() {
  local hex="$1"
  printf '%d' "0x${hex:0:8}"
}

ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
events_file="$artifact_dir/queue-pressure-events.ndjson"
summary_ndjson="$artifact_dir/queue-pressure-round-summary.ndjson"
: > "$events_file"
: > "$summary_ndjson"

queue_depth=0
peak_queue_depth=0
total_latency_ms=0
max_latency_ms=0
min_latency_ms=999999
total_dropped=0
total_arrivals=0
success_rounds=0

breach_reason="none"
breach_round=0
breach_metric=""
breach_observed=0
breach_threshold=0

for ((r=1; r<=rounds; r++)); do
  h="$(hash_hex "${seed}:round:${r}")"
  v="$(hex_to_dec8 "$h")"

  burst_multiplier=$(( 100 + (v % 70) )) # 100-169%
  round_arrivals=$(( tx_burst_size * burst_multiplier / 100 ))

  # A deterministic adversarial burst every 5th round.
  if (( r % 5 == 0 )); then
    round_arrivals=$(( round_arrivals + tx_burst_size / 2 ))
  fi

  available_capacity=$(( queue_capacity - queue_depth ))
  if (( available_capacity < 0 )); then
    available_capacity=0
  fi
  admitted=$round_arrivals
  dropped=0
  if (( admitted > available_capacity )); then
    dropped=$(( admitted - available_capacity ))
    admitted=$available_capacity
  fi
  queue_depth=$(( queue_depth + admitted ))

  # Drain a deterministic amount with small jitter.
  drain_jitter=$(( (v / 13) % 15 ))
  round_drain=$(( drain_rate_per_round - drain_jitter ))
  if (( round_drain < 1 )); then
    round_drain=1
  fi
  if (( round_drain > queue_depth )); then
    round_drain=$queue_depth
  fi
  queue_depth=$(( queue_depth - round_drain ))

  if (( queue_depth > peak_queue_depth )); then
    peak_queue_depth=$queue_depth
  fi

  backlog_factor=$(( queue_depth / 5 ))
  round_latency_ms=$(( base_latency_ms + (v % jitter_ms) + backlog_factor + (dropped * retry_penalty_ms / (tx_burst_size + 1)) ))

  if (( round_latency_ms > max_latency_ms )); then max_latency_ms=$round_latency_ms; fi
  if (( round_latency_ms < min_latency_ms )); then min_latency_ms=$round_latency_ms; fi
  total_latency_ms=$(( total_latency_ms + round_latency_ms ))
  total_dropped=$(( total_dropped + dropped ))
  total_arrivals=$(( total_arrivals + round_arrivals ))

  round_success=true
  if (( dropped > (round_arrivals / 2) )); then
    round_success=false
  fi
  if [[ "$round_success" == "true" ]]; then
    success_rounds=$((success_rounds + 1))
  fi

  if [[ "$breach_reason" == "none" ]]; then
    round_drop_rate=0
    if (( round_arrivals > 0 )); then
      round_drop_rate=$(( dropped * 100 / round_arrivals ))
    fi
    if (( round_drop_rate > envelope_max_drop_rate )); then
      breach_reason="drop_rate_threshold_breach"
      breach_round=$r
      breach_metric="round_drop_rate"
      breach_observed=$round_drop_rate
      breach_threshold=$envelope_max_drop_rate
    elif (( round_latency_ms > envelope_max_avg_latency_ms )); then
      breach_reason="latency_threshold_breach"
      breach_round=$r
      breach_metric="round_latency_ms"
      breach_observed=$round_latency_ms
      breach_threshold=$envelope_max_avg_latency_ms
    elif (( queue_depth > envelope_max_peak_queue )); then
      breach_reason="queue_depth_threshold_breach"
      breach_round=$r
      breach_metric="queue_depth"
      breach_observed=$queue_depth
      breach_threshold=$envelope_max_peak_queue
    fi
  fi

  printf '{"round":%d,"arrivals":%d,"admitted":%d,"dropped":%d,"drained":%d,"queue_depth":%d,"latency_ms":%d}\n' \
    "$r" "$round_arrivals" "$admitted" "$dropped" "$round_drain" "$queue_depth" "$round_latency_ms" >> "$events_file"
  printf '{"round":%d,"success":%s,"drop_rate_pct":%d,"queue_depth":%d,"latency_ms":%d}\n' \
    "$r" "$round_success" "$(( round_arrivals > 0 ? (dropped * 100 / round_arrivals) : 0 ))" "$queue_depth" "$round_latency_ms" >> "$summary_ndjson"
done

avg_latency_ms=$(( total_latency_ms / rounds ))
drop_rate_pct=0
if (( total_arrivals > 0 )); then
  drop_rate_pct=$(( total_dropped * 100 / total_arrivals ))
fi
success_rate=$(( success_rounds * 100 / rounds ))
latest_ledger_seq=$(( base_ledger_seq + rounds ))

status="pass"
if (( drop_rate_pct > envelope_max_drop_rate || avg_latency_ms > envelope_max_avg_latency_ms || peak_queue_depth > envelope_max_peak_queue )); then
  status="fail"
fi

cat > "$artifact_dir/queue-pressure-config.json" <<JSON
{
  "timestamp_utc": "$ts_iso",
  "scenario": "queue_pressure",
  "seed": "$seed",
  "cluster": { "nodes": $nodes, "rounds": $rounds, "base_ledger_seq": $base_ledger_seq },
  "driver": {
    "tx_burst_size": $tx_burst_size,
    "queue_capacity": $queue_capacity,
    "drain_rate_per_round": $drain_rate_per_round,
    "base_latency_ms": $base_latency_ms,
    "jitter_ms": $jitter_ms,
    "retry_penalty_ms": $retry_penalty_ms
  },
  "envelope": {
    "max_drop_rate_pct": $envelope_max_drop_rate,
    "max_avg_latency_ms": $envelope_max_avg_latency_ms,
    "max_peak_queue_depth": $envelope_max_peak_queue
  }
}
JSON

cat > "$artifact_dir/queue-pressure-summary.json" <<JSON
{
  "status": "$status",
  "scenario": "queue_pressure",
  "timestamp_utc": "$ts_iso",
  "deterministic": true,
  "cluster": {
    "nodes": $nodes,
    "rounds": $rounds,
    "seed": "$seed"
  },
  "metrics": {
    "success_rounds": $success_rounds,
    "success_rate": $success_rate,
    "tx_arrivals": $total_arrivals,
    "tx_dropped": $total_dropped,
    "drop_rate_pct": $drop_rate_pct,
    "latency_ms": {
      "avg": $avg_latency_ms,
      "min": $min_latency_ms,
      "max": $max_latency_ms
    },
    "peak_queue_depth": $peak_queue_depth,
    "latest_ledger_seq": $latest_ledger_seq
  },
  "envelope": {
    "max_drop_rate_pct": $envelope_max_drop_rate,
    "max_avg_latency_ms": $envelope_max_avg_latency_ms,
    "max_peak_queue_depth": $envelope_max_peak_queue
  },
  "artifacts": {
    "events": "queue-pressure-events.ndjson",
    "round_summary": "queue-pressure-round-summary.ndjson",
    "diagnostics": "queue-pressure-diagnostics.json"
  }
}
JSON

cat > "$artifact_dir/queue-pressure-diagnostics.json" <<JSON
{
  "scenario": "queue_pressure",
  "status": "$status",
  "deterministic": true,
  "root_cause": {
    "reason": "$breach_reason",
    "first_breach_round": $breach_round,
    "metric": "$breach_metric",
    "observed": $breach_observed,
    "threshold": $breach_threshold
  },
  "debug": {
    "peak_queue_depth": $peak_queue_depth,
    "avg_latency_ms": $avg_latency_ms,
    "drop_rate_pct": $drop_rate_pct
  }
}
JSON

echo "Queue-pressure scenario artifacts written to $artifact_dir"
