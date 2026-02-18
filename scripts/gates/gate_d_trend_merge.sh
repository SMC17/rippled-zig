#!/usr/bin/env bash
set -euo pipefail

input_dir="${1:-artifacts/gate-d/history}"
output_file="${2:-artifacts/gate-d/trend-summary-7d.json}"
max_points="${3:-200}"

mkdir -p "$(dirname "$output_file")"

tmp_points="$(mktemp)"
tmp_conf="$(mktemp)"
trap 'rm -f "$tmp_points" "$tmp_conf"' EXIT

find "$input_dir" -type f -name 'trend-point.json' 2>/dev/null | sort > "$tmp_points" || true
find "$input_dir" -type f -name 'testnet-conformance.json' 2>/dev/null | sort > "$tmp_conf" || true

if [[ ! -s "$tmp_points" && ! -s "$tmp_conf" ]]; then
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
trap 'rm -f "$tmp_points" "$tmp_conf" "$points_json"' EXIT

if [[ -s "$tmp_points" ]]; then
  jq -s '.' $(cat "$tmp_points") > "$points_json"
else
  echo '[]' > "$points_json"
fi

conf_json="$(mktemp)"
trap 'rm -f "$tmp_points" "$tmp_conf" "$points_json" "$conf_json"' EXIT

if [[ -s "$tmp_conf" ]]; then
  jq -s '.' $(cat "$tmp_conf") > "$conf_json"
else
  echo '[]' > "$conf_json"
fi

jq -n \
  --argjson max_points "$max_points" \
  --arg input_dir "$input_dir" \
  --slurpfile points "$points_json" \
  --slurpfile conf "$conf_json" '
  def to_num: if type=="number" then . else (tonumber? // null) end;
  def norm_status:
    if .=="pass" or .=="success" then "pass"
    elif .=="fail" or .=="failure" then "fail"
    elif .=="skipped" then "skipped"
    else "unknown" end;

  ($points[0] // []) as $p_all |
  ($conf[0] // []) as $c_all |
  ($p_all | map(select(.timestamp_utc != null)) | sort_by(.timestamp_utc) | reverse | .[:$max_points]) as $p_tail |
  ($c_all | map(select(.timestamp_utc != null)) | sort_by(.timestamp_utc) | reverse | .[:$max_points]) as $c_tail |
  {
    status: "ok",
    input_dir: $input_dir,
    window: "7d",
    points_considered: ($p_tail | length),
    conformance_records_considered: ($c_tail | length),
    summary: {
      success_rate: (
        if ($c_tail | length) == 0 then null
        else ((($c_tail | map(.status | norm_status == "pass") | map(if . then 1 else 0 end) | add) / ($c_tail | length)) * 100)
        end
      ),
      failure_count: ($c_tail | map(.status | norm_status == "fail") | map(if . then 1 else 0 end) | add // 0),
      skipped_count: ($c_tail | map(.status | norm_status == "skipped") | map(if . then 1 else 0 end) | add // 0),
      avg_latency_s: (
        if ($p_tail | length) == 0 then null
        else {
          server_info: (($p_tail | map(.latency_s.server_info | to_num) | map(select(. != null)) | add) / (($p_tail | map(.latency_s.server_info | to_num) | map(select(. != null)) | length) // 1)),
          fee: (($p_tail | map(.latency_s.fee | to_num) | map(select(. != null)) | add) / (($p_tail | map(.latency_s.fee | to_num) | map(select(. != null)) | length) // 1)),
          ledger: (($p_tail | map(.latency_s.ledger | to_num) | map(select(. != null)) | add) / (($p_tail | map(.latency_s.ledger | to_num) | map(select(. != null)) | length) // 1))
        }
        end
      ),
      latest_fail_reasons: ($c_tail | map(select((.status | norm_status)=="fail") | .reason) | map(select(. != null)) | .[:10])
    },
    latest_points: $p_tail,
    latest_conformance: $c_tail
  }
' > "$output_file"
