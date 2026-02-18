#!/usr/bin/env bash
set -euo pipefail

input_dir="${1:-artifacts/sim-local/history}"
output_file="${2:-artifacts/sim-local/sim-trend-summary-7d.json}"
max_points="${3:-200}"

mkdir -p "$(dirname "$output_file")"

tmp_points="$(mktemp)"
tmp_reports="$(mktemp)"
trap 'rm -f "$tmp_points" "$tmp_reports"' EXIT

find "$input_dir" -type f -name 'sim-trend-point.json' 2>/dev/null | sort > "$tmp_points" || true
find "$input_dir" -type f -name 'sim-gate-report.json' 2>/dev/null | sort > "$tmp_reports" || true

if [[ ! -s "$tmp_points" && ! -s "$tmp_reports" ]]; then
  cat > "$output_file" <<JSON
{
  "status": "no-data",
  "input_dir": "$input_dir",
  "window": "7d"
}
JSON
  exit 0
fi

points_json="$(mktemp)"
reports_json="$(mktemp)"
trap 'rm -f "$tmp_points" "$tmp_reports" "$points_json" "$reports_json"' EXIT

if [[ -s "$tmp_points" ]]; then
  jq -s '.' $(cat "$tmp_points") > "$points_json"
else
  echo '[]' > "$points_json"
fi
if [[ -s "$tmp_reports" ]]; then
  jq -s '.' $(cat "$tmp_reports") > "$reports_json"
else
  echo '[]' > "$reports_json"
fi

jq -n \
  --argjson max_points "$max_points" \
  --arg input_dir "$input_dir" \
  --slurpfile points "$points_json" \
  --slurpfile reports "$reports_json" '
  def to_num: if type=="number" then . else (tonumber? // null) end;
  def p95(values):
    (values | map(to_num) | map(select(. != null)) | sort) as $v |
    if ($v | length) == 0 then null
    else
      ($v | length) as $n |
      (((($n * 95 + 99) / 100) | floor) - 1) as $idx |
      $v[(if $idx < 0 then 0 else $idx end)]
    end;
  def norm_status:
    if .=="pass" or .=="success" then "pass"
    elif .=="fail" or .=="failure" then "fail"
    else "unknown" end;

  ($points[0] // []) as $p_all |
  ($reports[0] // []) as $r_all |
  ($p_all | map(select(.timestamp_utc != null)) | sort_by(.timestamp_utc) | reverse | .[:$max_points]) as $p_tail |
  ($r_all | map(select(.timestamp_utc != null)) | sort_by(.timestamp_utc) | reverse | .[:$max_points]) as $r_tail |
  {
    status: "ok",
    input_dir: $input_dir,
    window: "7d",
    points_considered: ($p_tail | length),
    gate_reports_considered: ($r_tail | length),
    summary: {
      success_rate: (
        if ($r_tail | length) == 0 then null
        else ((($r_tail | map(.status | norm_status == "pass") | map(if . then 1 else 0 end) | add) / ($r_tail | length)) * 100)
        end
      ),
      avg_success_rate: (
        if ($p_tail | length) == 0 then null
        else (($p_tail | map(.observed.success_rate | to_num) | map(select(. != null)) | add) / (($p_tail | map(.observed.success_rate | to_num) | map(select(. != null)) | length) // 1))
        end
      ),
      p95_avg_latency_ms: p95($p_tail | map(.observed.avg_latency_ms)),
      avg_nodes: (
        if ($p_tail | length) == 0 then null
        else (($p_tail | map(.observed.nodes | to_num) | map(select(. != null)) | add) / (($p_tail | map(.observed.nodes | to_num) | map(select(. != null)) | length) // 1))
        end
      ),
      latest_fail_reasons: ($r_tail | map(select((.status | norm_status)=="fail") | .reason) | map(select(. != null)) | .[:10])
    },
    latest_points: $p_tail,
    latest_gate_reports: $r_tail
  }
' > "$output_file"
