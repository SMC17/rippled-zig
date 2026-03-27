#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_ZIG="${ZIG_VERSION_EXPECTED:-$(awk '/^zig / { print $2; exit }' "$ROOT_DIR/.tool-versions")}"

if [[ -x "$ROOT_DIR/zig" ]]; then
  ZIG_BIN="$ROOT_DIR/zig"
else
  ZIG_BIN="$(command -v zig || true)"
fi

if [[ -z "${ZIG_BIN:-}" ]]; then
  echo "error: zig not found. Install Zig $EXPECTED_ZIG and ensure it is on PATH." >&2
  exit 1
fi

ACTUAL_ZIG="$("$ZIG_BIN" version)"
if [[ "$ACTUAL_ZIG" != "$EXPECTED_ZIG" ]]; then
  cat >&2 <<EOF
error: zig version mismatch
expected: $EXPECTED_ZIG
actual:   $ACTUAL_ZIG

Use one of:
- zigup $EXPECTED_ZIG
- asdf install
- mise install
EOF
  exit 1
fi

printf '%s\n' "$ZIG_BIN"
