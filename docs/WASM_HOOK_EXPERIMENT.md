# WASM Hook Experiment (Minimal)

Status: minimal hooks-oriented WASM example for experimentation and tooling validation.

## Purpose
Provide a reproducible path to build a tiny XRPL-Hooks-style WebAssembly module from Zig and document current constraints/limits.

This is an experiment/tooling path, not a production deployment guide.

## Example Source
- `examples/hook_template.zig`

Exports:
- `hook(reserved: u32) -> i64` (required)
- `cbak(what: u32) -> i64` (optional callback)

Behavior:
- accept-all placeholder (`return 0`)

## Reproducible Build Flow

Build just the hook example:
```bash
./zig build wasm-hook
```

Or build all wasm targets:
```bash
./zig build wasm
```

Expected output artifact:
- `zig-out/wasm/hook_template.wasm`

Optional local cache env (useful in sandboxed environments):
```bash
ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global-cache \
ZIG_LOCAL_CACHE_DIR=$PWD/.zig-cache \
./zig build wasm-hook
```

## Quick Validation (Local)

Basic checks:
1. File exists: `zig-out/wasm/hook_template.wasm`
2. File is non-empty
3. Build exited with code `0`

Optional export inspection (if tool available):
```bash
wasm-objdump -x zig-out/wasm/hook_template.wasm | rg 'hook|cbak'
```

## Runtime Constraints (Current State)

Current example intentionally avoids:
- Hook API host calls (`hook_param`, `etxn_details`, etc.)
- transaction field parsing
- state writes
- emitted transactions
- XRPL Hook fee budget accounting

Current repo support is focused on:
- compiling Zig to `wasm32-freestanding`
- stable example source for tooling and experimentation
- pairing with `tools/hook_gen.zig` for template/prompt generation workflows

## Current Limitations

- No end-to-end on-ledger Hook deployment pipeline in this repo
- No local XRPL Hook VM runtime emulator in gate coverage
- No ABI compatibility test suite against XRPL Hooks host imports
- No production safety guarantees for generated hook logic

## Experiment vs Production Boundary

This example is for:
- compiler/toolchain validation
- WASM artifact generation tests
- prototyping hook logic shape
- AI-assisted code generation experiments

This example is not sufficient for:
- production Hook deployment
- security-sensitive transaction logic
- financial policy enforcement
- correctness claims against XRPL Hooks runtime semantics

Before any production-oriented use:
1. Add ABI/import conformance tests
2. Add deterministic runtime validation against a Hooks-compatible environment
3. Add review/signing workflow for generated WASM artifacts
4. Document exact host function usage and failure semantics
