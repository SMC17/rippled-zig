#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/consensus-experiments}"
mkdir -p "$artifact_dir"

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

# Baseline config (defaults mirror consensus.zig)
base_final_threshold="${CONS_EXP_BASE_FINAL_THRESHOLD:-0.80}"
base_open_ticks="${CONS_EXP_BASE_OPEN_PHASE_TICKS:-20}"
base_open_ms="${CONS_EXP_BASE_OPEN_PHASE_MS:-2000}"
base_establish_ticks="${CONS_EXP_BASE_ESTABLISH_PHASE_TICKS:-5}"
base_round_ticks="${CONS_EXP_BASE_CONSENSUS_ROUND_TICKS:-5}"
base_validators="${CONS_EXP_BASE_VALIDATORS:-4}"
base_max_iter="${CONS_EXP_BASE_MAX_ITERATIONS:-200}"

# Variant config (defaults intentionally differ for comparison)
var_final_threshold="${CONS_EXP_VAR_FINAL_THRESHOLD:-0.70}"
var_open_ticks="${CONS_EXP_VAR_OPEN_PHASE_TICKS:-10}"
var_open_ms="${CONS_EXP_VAR_OPEN_PHASE_MS:-1000}"
var_establish_ticks="${CONS_EXP_VAR_ESTABLISH_PHASE_TICKS:-3}"
var_round_ticks="${CONS_EXP_VAR_CONSENSUS_ROUND_TICKS:-2}"
var_validators="${CONS_EXP_VAR_VALIDATORS:-4}"
var_max_iter="${CONS_EXP_VAR_MAX_ITERATIONS:-200}"

cat > "$artifact_dir/baseline-config.json" <<JSON
{
  "schema_version": 1,
  "label": "baseline",
  "final_threshold": $base_final_threshold,
  "open_phase_ticks": $base_open_ticks,
  "open_phase_ms": $base_open_ms,
  "establish_phase_ticks": $base_establish_ticks,
  "consensus_round_ticks": $base_round_ticks,
  "validators": $base_validators,
  "max_iterations": $base_max_iter
}
JSON

cat > "$artifact_dir/variant-config.json" <<JSON
{
  "schema_version": 1,
  "label": "variant",
  "final_threshold": $var_final_threshold,
  "open_phase_ticks": $var_open_ticks,
  "open_phase_ms": $var_open_ms,
  "establish_phase_ticks": $var_establish_ticks,
  "consensus_round_ticks": $var_round_ticks,
  "validators": $var_validators,
  "max_iterations": $var_max_iter
}
JSON

CONS_EXP_LABEL=baseline \
CONS_EXP_FINAL_THRESHOLD="$base_final_threshold" \
CONS_EXP_OPEN_PHASE_TICKS="$base_open_ticks" \
CONS_EXP_OPEN_PHASE_MS="$base_open_ms" \
CONS_EXP_ESTABLISH_PHASE_TICKS="$base_establish_ticks" \
CONS_EXP_CONSENSUS_ROUND_TICKS="$base_round_ticks" \
CONS_EXP_VALIDATORS="$base_validators" \
CONS_EXP_MAX_ITERATIONS="$base_max_iter" \
"$ZIG_BIN" build consensus-experiment -- "$artifact_dir/baseline-summary.json"

CONS_EXP_LABEL=variant \
CONS_EXP_FINAL_THRESHOLD="$var_final_threshold" \
CONS_EXP_OPEN_PHASE_TICKS="$var_open_ticks" \
CONS_EXP_OPEN_PHASE_MS="$var_open_ms" \
CONS_EXP_ESTABLISH_PHASE_TICKS="$var_establish_ticks" \
CONS_EXP_CONSENSUS_ROUND_TICKS="$var_round_ticks" \
CONS_EXP_VALIDATORS="$var_validators" \
CONS_EXP_MAX_ITERATIONS="$var_max_iter" \
"$ZIG_BIN" build consensus-experiment -- "$artifact_dir/variant-summary.json"

jq -n \
  --slurpfile base "$artifact_dir/baseline-summary.json" \
  --slurpfile variant "$artifact_dir/variant-summary.json" \
  '{
    schema_version: 1,
    deterministic: true,
    baseline: $base[0],
    variant: $variant[0],
    comparison: {
      accepted_both: (($base[0].result.accepted == true) and ($variant[0].result.accepted == true)),
      iterations_delta: ($variant[0].result.iterations_executed - $base[0].result.iterations_executed),
      proposals_delta: ($variant[0].result.proposals_received - $base[0].result.proposals_received),
      same_validator_count: ($variant[0].result.validators == $base[0].result.validators)
    }
  }' > "$artifact_dir/comparison.json"

echo "Consensus experiment artifacts written to $artifact_dir"
