#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -x "$ROOT_DIR/zig" ]]; then
  ZIG_BIN="$ROOT_DIR/zig"
else
  ZIG_BIN="$(command -v zig)"
fi

if [[ -z "${ZIG_BIN:-}" ]]; then
  echo "error: zig not found. Install Zig 0.15.1 or run zigup first." >&2
  exit 1
fi

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT_DIR/.zig-global-cache}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$ROOT_DIR/.zig-cache}"

exec "$ZIG_BIN" build run "$@"
