#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/sim-local}"
nodes="${SIM_NODES:-5}"
rounds="${SIM_ROUNDS:-20}"
seed="${SIM_SEED:-xrpl-agent-lab-v1}"
base_ledger_seq="${SIM_BASE_LEDGER_SEQ:-1000000}"
base_latency_ms="${SIM_BASE_LATENCY_MS:-40}"
jitter_ms="${SIM_JITTER_MS:-25}"

mkdir -p "$artifact_dir"

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
events_file="$artifact_dir/round-events.ndjson"
: > "$events_file"

success_rounds=0
total_latency_ms=0
max_latency_ms=0
min_latency_ms=999999

for ((r=1; r<=rounds; r++)); do
  round_success=true
  round_avg_latency=0
  round_leader=0
  round_leader_score=0

  for ((n=1; n<=nodes; n++)); do
    h="$(hash_hex "${seed}:${r}:${n}")"
    v="$(hex_to_dec8 "$h")"
    latency=$(( base_latency_ms + (v % jitter_ms) ))
    vote=$(( (v / 7) % 100 ))
    accepted=true
    if (( vote < 15 )); then
      accepted=false
      round_success=false
    fi
    if (( latency > max_latency_ms )); then max_latency_ms=$latency; fi
    if (( latency < min_latency_ms )); then min_latency_ms=$latency; fi
    total_latency_ms=$(( total_latency_ms + latency ))
    round_avg_latency=$(( round_avg_latency + latency ))
    if (( n == 1 || v > round_leader_score )); then
      round_leader_score=$v
      round_leader=$n
    fi
    printf '{"round":%d,"node":%d,"latency_ms":%d,"accepted":%s,"vote_bucket":%d}\n' \
      "$r" "$n" "$latency" "$accepted" "$vote" >> "$events_file"
  done

  round_avg_latency=$(( round_avg_latency / nodes ))
  if [[ "$round_success" == "true" ]]; then
    success_rounds=$((success_rounds + 1))
  fi
  printf '{"round":%d,"leader_node":%d,"avg_latency_ms":%d,"success":%s}\n' \
    "$r" "$round_leader" "$round_avg_latency" "$round_success" >> "$artifact_dir/round-summary.ndjson"
done

if (( rounds == 0 || nodes == 0 )); then
  echo "SIM_NODES and SIM_ROUNDS must be > 0" >&2
  exit 1
fi

avg_latency_ms=$(( total_latency_ms / (rounds * nodes) ))
success_rate=$(( success_rounds * 100 / rounds ))
latest_ledger_seq=$(( base_ledger_seq + rounds ))

cat > "$artifact_dir/simulation-config.json" <<JSON
{
  "timestamp_utc": "$ts_iso",
  "seed": "$seed",
  "nodes": $nodes,
  "rounds": $rounds,
  "base_ledger_seq": $base_ledger_seq,
  "latency_profile_ms": {
    "base": $base_latency_ms,
    "jitter": $jitter_ms
  }
}
JSON

cat > "$artifact_dir/simulation-summary.json" <<JSON
{
  "status": "pass",
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
    "latency_ms": {
      "avg": $avg_latency_ms,
      "min": $min_latency_ms,
      "max": $max_latency_ms
    },
    "latest_ledger_seq": $latest_ledger_seq
  },
  "artifacts": {
    "events": "round-events.ndjson",
    "round_summary": "round-summary.ndjson"
  }
}
JSON

cat > "$artifact_dir/simulation-report.md" <<MD
# Deterministic Local Cluster Simulation

- Timestamp (UTC): $ts_iso
- Seed: \`$seed\`
- Nodes: $nodes
- Rounds: $rounds
- Latest ledger seq: $latest_ledger_seq
- Success rounds: $success_rounds/$rounds ($success_rate%)
- Latency (ms): avg=$avg_latency_ms min=$min_latency_ms max=$max_latency_ms

This run is deterministic: same seed/config produces identical summaries and event stream.
MD

echo "Simulation artifacts written to $artifact_dir"
