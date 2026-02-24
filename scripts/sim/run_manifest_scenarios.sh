#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/sim-manifest}"
manifest="${2:-test_data/sim_scenarios_manifest.json}"
mkdir -p "$artifact_dir"

if [[ ! -f "$manifest" ]]; then
  echo "Missing manifest: $manifest" >&2
  exit 1
fi

for cmd in jq bash; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required tool: $cmd" >&2
    exit 1
  fi
done

if ! jq -e '.schema_version == 1 and .manifest_type == "simulation_scenarios" and (.scenarios|type=="array" and length>0)' "$manifest" >/dev/null; then
  echo "Invalid simulation scenario manifest header/schema" >&2
  exit 1
fi

count="$(jq -r '.scenarios | length' "$manifest")"
for ((i=0; i<count; i++)); do
  scenario_id="$(jq -r ".scenarios[$i].scenario_id" "$manifest")"
  driver="$(jq -r ".scenarios[$i].driver" "$manifest")"
  nodes="$(jq -r ".scenarios[$i].node_count" "$manifest")"
  rounds="$(jq -r ".scenarios[$i].rounds" "$manifest")"
  seed="$(jq -r ".scenarios[$i].seed" "$manifest")"

  out="$artifact_dir/$scenario_id"
  mkdir -p "$out"

  scenario_mode="standard"
  case "$driver" in
    run_local_cluster)
      scenario_mode="standard"
      ;;
    run_queue_pressure_scenario)
      scenario_mode="queue_pressure"
      ;;
    *)
      echo "Unsupported scenario driver in manifest: $driver" >&2
      exit 1
      ;;
  esac

  PATH="${PATH}" \
  ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-global-cache}" \
  ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache}" \
  SIM_NODES="$nodes" \
  SIM_ROUNDS="$rounds" \
  SIM_SEED="$seed" \
  GATE_SIM_SCENARIO="$scenario_mode" \
  GATE_SIM_SCENARIO_MANIFEST="$manifest" \
  bash scripts/gates/gate_sim.sh "$out"
done

tmp_summary="$(mktemp)"
trap 'rm -f "$tmp_summary"' EXIT

jq -n --arg manifest "$manifest" '
  {
    schema_version: 1,
    manifest_type: "simulation_manifest_batch_run",
    deterministic: true,
    manifest: $manifest,
    scenarios: []
  }
' > "$tmp_summary"

for ((i=0; i<count; i++)); do
  scenario_id="$(jq -r ".scenarios[$i].scenario_id" "$manifest")"
  driver="$(jq -r ".scenarios[$i].driver" "$manifest")"
  seed="$(jq -r ".scenarios[$i].seed" "$manifest")"
  out="$artifact_dir/$scenario_id"

  if [[ "$driver" == "run_queue_pressure_scenario" ]]; then
    summary_file="$out/queue-pressure-summary.json"
    metrics_expr='{
      success_rate: (.metrics.success_rate // null),
      latest_ledger_seq: (.metrics.latest_ledger_seq // null),
      avg_latency_ms: (.metrics.latency_ms.avg // null),
      drop_rate_pct: (.metrics.drop_rate_pct // null),
      peak_queue_depth: (.metrics.peak_queue_depth // null)
    }'
  else
    summary_file="$out/simulation-summary.json"
    metrics_expr='{
      success_rate: (.metrics.success_rate // null),
      latest_ledger_seq: (.metrics.latest_ledger_seq // null),
      avg_latency_ms: (.metrics.latency_ms.avg // null)
    }'
  fi

  scenario_json="$(jq -n \
    --arg scenario_id "$scenario_id" \
    --arg driver "$driver" \
    --arg seed "$seed" \
    --arg artifact_dir "$scenario_id" \
    --argjson gate "$(cat "$out/sim-gate-report.json")" \
    --argjson summary "$(cat "$summary_file")" \
    --arg metrics_expr "$metrics_expr" '
    {
      scenario_id: $scenario_id,
      driver: $driver,
      seed: $seed,
      gate_status: ($gate.status // "unknown"),
      summary_status: ($summary.status // "unknown"),
      deterministic: ($summary.deterministic // false),
      artifact_dir: $artifact_dir,
      metrics: (
        if $driver == "run_queue_pressure_scenario" then
          {
            success_rate: ($summary.metrics.success_rate // null),
            latest_ledger_seq: ($summary.metrics.latest_ledger_seq // null),
            avg_latency_ms: ($summary.metrics.latency_ms.avg // null),
            drop_rate_pct: ($summary.metrics.drop_rate_pct // null),
            peak_queue_depth: ($summary.metrics.peak_queue_depth // null)
          }
        else
          {
            success_rate: ($summary.metrics.success_rate // null),
            latest_ledger_seq: ($summary.metrics.latest_ledger_seq // null),
            avg_latency_ms: ($summary.metrics.latency_ms.avg // null)
          }
        end
      )
    }')"

  jq --argjson scenario "$scenario_json" '.scenarios += [$scenario]' "$tmp_summary" > "$tmp_summary.next"
  mv "$tmp_summary.next" "$tmp_summary"
done

mv "$tmp_summary" "$artifact_dir/manifest-scenarios-summary.json"
trap - EXIT
echo "Manifest scenarios written to $artifact_dir"
