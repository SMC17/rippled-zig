#!/usr/bin/env bash
# Produce release artifacts with checksum provenance.
# Run from repo root. Output: zig-out/release/ with binaries + SHA256SUMS
set -euo pipefail

out="${1:-zig-out/release}"
mkdir -p "$out"

zig build -Doptimize=ReleaseSafe
zig build wasm

# Copy artifacts
cp -f zig-out/bin/rippled-zig "$out/" 2>/dev/null || true
cp -f zig-out/wasm/protocol_kernel.wasm "$out/" 2>/dev/null || true
cp -f zig-out/wasm/hook_template.wasm "$out/" 2>/dev/null || true

# Generate checksums (provenance)
(cd "$out" && shasum -a 256 -b *.wasm rippled-zig 2>/dev/null | tee SHA256SUMS) || true

# Provenance manifest
cat > "$out/PROVENANCE.json" <<JSON
{
  "version": "1.0",
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "artifacts": ["rippled-zig", "protocol_kernel.wasm", "hook_template.wasm"],
  "checksums": "SHA256SUMS"
}
JSON

echo "Release artifacts in $out"
