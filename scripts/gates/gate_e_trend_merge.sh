#!/usr/bin/env bash
set -euo pipefail

input_dir="${1:-artifacts/gate-e/history}"
output_file="${2:-artifacts/gate-e/security-trend-summary-7d.json}"
max_points="${3:-200}"

mkdir -p "$(dirname "$output_file")"

tmp_metrics="$(mktemp)"
trap 'rm -f "$tmp_metrics"' EXIT

find "$input_dir" -type f -name 'security-metrics.json' 2>/dev/null | sort > "$tmp_metrics" || true

if [[ ! -s "$tmp_metrics" ]]; then
  cat > "$output_file" <<JSON
{
  "status": "no-data",
  "input_dir": "$input_dir",
  "window": "7d"
}
JSON
  exit 0
fi

metrics_json="$(mktemp)"
trap 'rm -f "$tmp_metrics" "$metrics_json"' EXIT
jq -s '.' $(cat "$tmp_metrics") > "$metrics_json"

jq -n \
  --argjson max_points "$max_points" \
  --arg input_dir "$input_dir" \
  --slurpfile metrics "$metrics_json" '
  def to_num: if type=="number" then . else (tonumber? // null) end;
  def p95(values):
    (values | map(to_num) | map(select(. != null)) | sort) as $v |
    if ($v | length) == 0 then null
    else
      ($v | length) as $n |
      (((($n * 95 + 99) / 100) | floor) - 1) as $idx |
      $v[(if $idx < 0 then 0 else $idx end)]
    end;
  ($metrics[0] // []) as $all |
  ($all | map(select(.timestamp_utc != null)) | sort_by(.timestamp_utc) | reverse | .[:$max_points]) as $tail |
  {
    status: "ok",
    input_dir: $input_dir,
    window: "7d",
    points_considered: ($tail | length),
    summary: {
      success_rate: (
        if ($tail | length) == 0 then null
        else ((($tail | map(.status == "pass") | map(if . then 1 else 0 end) | add) / ($tail | length)) * 100)
        end
      ),
      avg_runtime_s: (
        if ($tail | length) == 0 then null
        else (($tail | map(.observed.runtime_s | to_num) | map(select(. != null)) | add) / (($tail | map(.observed.runtime_s | to_num) | map(select(. != null)) | length) // 1))
        end
      ),
      avg_fuzz_cases: (
        if ($tail | length) == 0 then null
        else (($tail | map(.observed.fuzz_cases | to_num) | map(select(. != null)) | add) / (($tail | map(.observed.fuzz_cases | to_num) | map(select(. != null)) | length) // 1))
        end
      ),
      p95_runtime_s: p95($tail | map(.observed.runtime_s)),
      crash_free_failures: ($tail | map(select((.observed.crash_free | to_num) != 1)) | length),
      crash_free_rate: (
        if ($tail | length) == 0 then null
        else (((($tail | map(select((.observed.crash_free | to_num) == 1)) | length) / ($tail | length)) * 100))
        end
      )
    },
    latest_metrics: $tail
  }
' > "$output_file"
