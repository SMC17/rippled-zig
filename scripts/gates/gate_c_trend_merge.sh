#!/usr/bin/env bash
set -euo pipefail

input_dir="${1:-artifacts/gate-c/history}"
output_file="${2:-artifacts/gate-c/crypto-trend-summary-7d.json}"
max_points="${3:-200}"

mkdir -p "$(dirname "$output_file")"

tmp_reports="$(mktemp)"
trap 'rm -f "$tmp_reports"' EXIT

find "$input_dir" -type f -name 'parity-report.json' 2>/dev/null | sort > "$tmp_reports" || true

if [[ ! -s "$tmp_reports" ]]; then
  cat > "$output_file" <<JSON
{
  "status": "no-data",
  "input_dir": "$input_dir",
  "window": "7d"
}
JSON
  exit 0
fi

reports_json="$(mktemp)"
trap 'rm -f "$tmp_reports" "$reports_json"' EXIT
jq -s '.' $(cat "$tmp_reports") > "$reports_json"

jq -n \
  --argjson max_points "$max_points" \
  --arg input_dir "$input_dir" \
  --slurpfile reports "$reports_json" '
  def to_num: if type=="number" then . else (tonumber? // null) end;
  def is_pass: .status == "pass";
  def strict_enabled: (.strict_crypto == "true");

  ($reports[0] // []) as $all |
  ($all | map(select(.timestamp_utc != null)) | sort_by(.timestamp_utc) | reverse | .[:$max_points]) as $tail |
  {
    status: "ok",
    input_dir: $input_dir,
    window: "7d",
    points_considered: ($tail | length),
    summary: {
      success_rate: (
        if ($tail | length) == 0 then null
        else ((($tail | map(is_pass) | map(if . then 1 else 0 end) | add) / ($tail | length)) * 100)
        end
      ),
      strict_runs: ($tail | map(select(strict_enabled)) | length),
      strict_passes: ($tail | map(select(strict_enabled and is_pass)) | length),
      avg_positive_vectors: (
        if ($tail | length) == 0 then null
        else (($tail | map(.crypto_vectors.positive | to_num) | map(select(. != null)) | add) / (($tail | map(.crypto_vectors.positive | to_num) | map(select(. != null)) | length) // 1))
        end
      ),
      avg_negative_vectors: (
        if ($tail | length) == 0 then null
        else (($tail | map(.crypto_vectors.negative | to_num) | map(select(. != null)) | add) / (($tail | map(.crypto_vectors.negative | to_num) | map(select(. != null)) | length) // 1))
        end
      ),
      avg_signing_domain_checks: (
        if ($tail | length) == 0 then null
        else (($tail | map(.crypto_vectors.signing_domain | to_num) | map(select(. != null)) | add) / (($tail | map(.crypto_vectors.signing_domain | to_num) | map(select(. != null)) | length) // 1))
        end
      ),
      consecutive_strict_passes_from_latest: (
        $tail
        | reduce .[] as $r ({count:0,active:true};
            if .active and ($r.strict_crypto == "true") and ($r.status == "pass") then .count += 1
            else .active = false
            end
          )
        | .count
      )
    },
    latest_reports: $tail
  }
' > "$output_file"
