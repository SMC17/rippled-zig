#!/usr/bin/env bash
# Richer multi-node scenarios for agent training and evaluation.
# Runs multiple configs and produces aggregated trend summaries.
set -euo pipefail

base_dir="${1:-artifacts/sim-agent}"
mkdir -p "$base_dir"

scenarios=(
  "standard:5:20:xrpl-agent-default:40:25"
  "training:7:50:xrpl-agent-training:40:25"
  "stress:5:30:xrpl-agent-stress:60:50"
)

for spec in "${scenarios[@]}"; do
  IFS=: read -r label nodes rounds seed base_ms jitter_ms <<< "$spec"
  out="$base_dir/$label"
  mkdir -p "$out"
  SIM_NODES="$nodes" SIM_ROUNDS="$rounds" SIM_SEED="$seed" \
    SIM_BASE_LATENCY_MS="$base_ms" SIM_JITTER_MS="$jitter_ms" \
    scripts/sim/run_local_cluster.sh "$out"
done

# Aggregate trend summary for agent consumption
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
cat > "$base_dir/scenarios-summary.json" <<JSON
{
  "timestamp_utc": "$ts_iso",
  "scenarios": ["standard", "training", "stress"],
  "base_dir": "$base_dir",
  "usage": "Agent training: ingest round-events.ndjson and round-summary.ndjson per scenario"
}
JSON

echo "Agent scenarios written to $base_dir"
