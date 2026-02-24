#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-artifacts/consensus-experiment-matrix}"
manifest_file="${2:-test_data/consensus_experiment_matrix_manifest.json}"
mkdir -p "$artifact_dir"

ZIG_BIN="${ZIG_BIN:-${PWD}/zig}"
if [[ ! -x "$ZIG_BIN" ]]; then
  ZIG_BIN="$(command -v zig)"
fi
if [[ -z "${ZIG_BIN:-}" ]]; then
  echo "error: zig not found" >&2
  exit 1
fi

for cmd in jq awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not found" >&2; exit 1; }
done

if [[ ! -f "$manifest_file" ]]; then
  echo "error: manifest file not found: $manifest_file" >&2
  exit 1
fi

if ! jq -e '
  .schema_version == 1 and
  .manifest_type == "consensus_experiment_matrix" and
  .deterministic == true and
  (.experiments | type == "array" and length >= 3) and
  (all(.experiments[];
    (.label | type == "string" and length > 0) and
    (.validators | type == "number") and
    (.max_iterations | type == "number") and
    (.config | type == "object") and
    (.config.final_threshold | type == "number") and
    (.config.open_phase_ticks | type == "number") and
    (.config.open_phase_ms | type == "number") and
    (.config.establish_phase_ticks | type == "number") and
    (.config.consensus_round_ticks | type == "number")
  )) and
  ((.experiments | map(.label) | unique | length) == (.experiments | length))
' "$manifest_file" >/dev/null; then
  echo "error: invalid consensus experiment matrix manifest schema: $manifest_file" >&2
  exit 1
fi

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-global-cache}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache}"

tmp_labels="$(mktemp)"
tmp_summary_paths="$(mktemp)"
trap 'rm -f "$tmp_labels" "$tmp_summary_paths"' EXIT
jq -r '.experiments[].label' "$manifest_file" > "$tmp_labels"
: > "$tmp_summary_paths"

while IFS= read -r label; do
  exp_cfg="$artifact_dir/${label}-config.json"
  exp_summary="$artifact_dir/${label}-summary.json"

  jq -e --arg exp_label "$label" '.experiments[] | select(.label == $exp_label)' "$manifest_file" > "$exp_cfg"

  validators="$(jq -r '.validators' "$exp_cfg")"
  max_iterations="$(jq -r '.max_iterations' "$exp_cfg")"
  final_threshold="$(jq -r '.config.final_threshold' "$exp_cfg")"
  open_phase_ticks="$(jq -r '.config.open_phase_ticks' "$exp_cfg")"
  open_phase_ms="$(jq -r '.config.open_phase_ms' "$exp_cfg")"
  establish_phase_ticks="$(jq -r '.config.establish_phase_ticks' "$exp_cfg")"
  consensus_round_ticks="$(jq -r '.config.consensus_round_ticks' "$exp_cfg")"

  CONS_EXP_LABEL="$label" \
  CONS_EXP_VALIDATORS="$validators" \
  CONS_EXP_MAX_ITERATIONS="$max_iterations" \
  CONS_EXP_FINAL_THRESHOLD="$final_threshold" \
  CONS_EXP_OPEN_PHASE_TICKS="$open_phase_ticks" \
  CONS_EXP_OPEN_PHASE_MS="$open_phase_ms" \
  CONS_EXP_ESTABLISH_PHASE_TICKS="$establish_phase_ticks" \
  CONS_EXP_CONSENSUS_ROUND_TICKS="$consensus_round_ticks" \
  "$ZIG_BIN" build consensus-experiment -- "$exp_summary"

  if ! jq -e '
    .schema_version == 1 and
    .deterministic == true and
    (.label | type == "string") and
    (.config | type == "object") and
    (.inputs | type == "object") and
    (.result | type == "object") and
    (.result.accepted | type == "boolean") and
    (.result.iterations_executed | type == "number") and
    (.result.validators | type == "number")
  ' "$exp_summary" >/dev/null; then
    echo "error: invalid experiment summary schema: $exp_summary" >&2
    exit 1
  fi

  printf '%s\n' "$exp_summary" >> "$tmp_summary_paths"
done < "$tmp_labels"

jq -n \
  --arg manifest_file "$manifest_file" \
  --slurpfile manifest "$manifest_file" \
  --argjson experiments "$(jq -s '.' $(cat "$tmp_summary_paths"))" '
  ($manifest[0]) as $m |
  ($experiments | sort_by(.label)) as $exps |
  ($exps[0]) as $baseline |
  {
    schema_version: 1,
    deterministic: true,
    manifest_type: "consensus_experiment_matrix_summary",
    manifest_source: $manifest_file,
    experiments_executed: ($exps | length),
    labels: ($exps | map(.label)),
    experiments: $exps,
    comparison: {
      baseline_label: ($baseline.label // null),
      accepted_count: ($exps | map(select(.result.accepted == true)) | length),
      rejected_count: ($exps | map(select(.result.accepted != true)) | length),
      max_iterations_executed: ($exps | map(.result.iterations_executed) | max),
      min_iterations_executed: ($exps | map(.result.iterations_executed) | min),
      deltas_vs_baseline: (
        if $baseline == null then []
        else
          ($exps | map({
            label: .label,
            iterations_delta: (.result.iterations_executed - $baseline.result.iterations_executed),
            proposals_delta: (.result.proposals_received - $baseline.result.proposals_received),
            accepted_same_as_baseline: (.result.accepted == $baseline.result.accepted),
            validator_delta: (.result.validators - $baseline.result.validators)
          }))
        end
      )
    }
  }
' > "$artifact_dir/matrix-summary.json"

if ! jq -e '
  .schema_version == 1 and
  .deterministic == true and
  .manifest_type == "consensus_experiment_matrix_summary" and
  (.experiments_executed | type == "number" and . >= 3) and
  (.labels | type == "array" and length >= 3) and
  (.experiments | type == "array" and length >= 3) and
  (.comparison | type == "object") and
  (.comparison.deltas_vs_baseline | type == "array")
' "$artifact_dir/matrix-summary.json" >/dev/null; then
  echo "error: invalid matrix summary schema: $artifact_dir/matrix-summary.json" >&2
  exit 1
fi

echo "Consensus experiment matrix artifacts written to $artifact_dir"
