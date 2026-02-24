#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:?artifact_dir required}"
scenario="${2:-standard}"

if [[ "$scenario" == "queue_pressure" ]]; then
  summary_file="$artifact_dir/queue-pressure-summary.json"
  config_file="$artifact_dir/queue-pressure-config.json"
else
  summary_file="$artifact_dir/simulation-summary.json"
  config_file="$artifact_dir/simulation-config.json"
fi

if [[ ! -f "$summary_file" ]]; then
  echo "Missing simulation summary for invariants: $summary_file" >&2
  exit 1
fi
if [[ ! -f "$config_file" ]]; then
  echo "Missing simulation config for invariants: $config_file" >&2
  exit 1
fi

nodes="$(jq -r '.cluster.nodes // .nodes // 0' "$summary_file")"
rounds="$(jq -r '.cluster.rounds // .rounds // 0' "$summary_file")"
latest_ledger_seq="$(jq -r '.metrics.latest_ledger_seq // 0' "$summary_file")"
base_ledger_seq="$(jq -r '.cluster.base_ledger_seq // .base_ledger_seq // 0' "$config_file")"

ZIG_BIN="${ZIG_BIN:-${PWD}/zig}"
if [[ ! -x "$ZIG_BIN" ]]; then
  ZIG_BIN="$(command -v zig)"
fi
if [[ -z "${ZIG_BIN:-}" ]]; then
  echo "error: zig not found" >&2
  exit 1
fi

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-global-cache}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache}"
export INV_SCENARIO="$scenario"
export INV_NODES="$nodes"
export INV_ROUNDS="$rounds"
export INV_BASE_LEDGER_SEQ="$base_ledger_seq"
export INV_LATEST_LEDGER_SEQ="$latest_ledger_seq"
export INV_FAIL_MODE="${SIM_INVARIANT_FAIL_MODE:-none}"

out_file="$artifact_dir/protocol-invariants.json"
if "$ZIG_BIN" run src/invariant_probe.zig -- "$out_file"; then
  echo "Invariant checks passed for scenario $scenario"
  exit 0
fi

echo "Invariant checks failed for scenario $scenario" >&2
exit 1
