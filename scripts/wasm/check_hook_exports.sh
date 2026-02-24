#!/usr/bin/env bash
set -euo pipefail

wasm_path="${1:-zig-out/wasm/hook_template.wasm}"
artifact_dir="${2:-artifacts/wasm-hook-export-check}"
mkdir -p "$artifact_dir"

fail() {
  local reason="$1"
  local escaped="${reason//\"/\\\"}"
  echo "$reason" | tee "$artifact_dir/failure.txt"
  cat > "$artifact_dir/hook-wasm-export-check.json" <<JSON
{
  "status": "fail",
  "wasm_path": "$wasm_path",
  "reason": "$escaped"
}
JSON
  exit 1
}

[[ -f "$wasm_path" ]] || fail "WASM file not found: $wasm_path"
[[ -s "$wasm_path" ]] || fail "WASM file is empty: $wasm_path"

tool_used="none"
export_lines_file="$artifact_dir/exports.raw.txt"

if command -v wasm-objdump >/dev/null 2>&1; then
  tool_used="wasm-objdump"
  wasm-objdump -x "$wasm_path" > "$export_lines_file"
elif command -v wasm-tools >/dev/null 2>&1; then
  tool_used="wasm-tools"
  wasm-tools print "$wasm_path" > "$export_lines_file"
elif command -v strings >/dev/null 2>&1; then
  tool_used="strings"
  strings -a "$wasm_path" > "$export_lines_file"
else
  fail "No export inspection tool available (need wasm-objdump, wasm-tools, or strings)"
fi

has_hook=0
has_cbak=0
if grep -Fxq 'hook' "$export_lines_file" || grep -Eq 'export.*hook|func\[.*\] <hook>|\"hook\"' "$export_lines_file"; then
  has_hook=1
fi
if grep -Fxq 'cbak' "$export_lines_file" || grep -Eq 'export.*cbak|func\[.*\] <cbak>|\"cbak\"' "$export_lines_file"; then
  has_cbak=1
fi

if [[ "$has_hook" != "1" ]]; then
  fail "Required hook export not detected"
fi

cat > "$artifact_dir/hook-wasm-export-check.json" <<JSON
{
  "status": "pass",
  "wasm_path": "$wasm_path",
  "tool_used": "$tool_used",
  "export_contract": {
    "required": ["hook"],
    "optional": ["cbak"]
  },
  "observed": {
    "hook": true,
    "cbak": $( [[ "$has_cbak" == "1" ]] && echo true || echo false )
  },
  "notes": {
    "scope": "export smoke check only",
    "abi_runtime_compatibility": "not validated"
  }
}
JSON

if ! jq -e '
  .status == "pass" and
  (.wasm_path | type == "string") and
  (.tool_used | type == "string") and
  (.export_contract.required == ["hook"]) and
  (.export_contract.optional == ["cbak"]) and
  (.observed.hook == true) and
  (.observed.cbak == true or .observed.cbak == false)
' "$artifact_dir/hook-wasm-export-check.json" >/dev/null; then
  fail "Generated export-check artifact schema invalid"
fi

echo "hook export check passed ($tool_used): $wasm_path"
