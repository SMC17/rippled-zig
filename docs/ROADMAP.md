# Roadmap

Status: Active roadmap for `main` as of March 15, 2026.

Canonical companion docs:
- `PROJECT_STATUS.md` (release decision + evidence register)
- `docs/status/ARCHITECTURE_SOT.md` (module maturity/ownership/risk)
- `docs/status/AGENT_NATIVE_BACKLOG.md` (prioritized backlog)

## Planning Rules
1. Gate-backed evidence before maturity claims.
2. Narrow product scope before broadening implementation.
3. Deterministic contracts before broad API surface.
4. Research and production behaviors are explicitly separated.

## Active Release Target
- Milestone: `v1 XRPL Toolkit`
- Epic: `#45` https://github.com/SMC17/rippled-zig/issues/45
- Child issues: `#46`-`#62`
- Target date: `2026-07-31`
- Product target:
  - Canonical XRPL transaction encoding for a declared supported set
  - Signing-hash generation and signature verification with strict evidence
  - Selected live RPC conformance with pinned schemas and artifacts
  - Stable Zig library and CLI surface
- Explicitly not part of v1:
  - validator readiness
  - full P2P overlay compatibility
  - ledger sync parity
  - consensus parity
  - storage durability claims

## Milestones

| Milestone | Objective | Status | Exit Evidence |
|---|---|---|---|
| M0 | Scope freeze + toolchain parity (`#46`, `#47`, `#61`) | In progress | docs updated, default build narrowed, Zig `0.14.1` enforced locally and in CI |
| M1 | Canonical codec + fixture corpus (`#48`, `#49`, `#50`) | Planned | Gate B deterministic vectors and fixture manifest updated for the v1 transaction set |
| M2 | Signing/crypto correctness (`#51`, `#52`, `#53`, `#54`) | Planned | strict signing-hash + verification evidence in Gate C |
| M3 | Live subset and release evidence (`#55`, `#56`, `#57`) | Planned | Gate C/Gate D evidence for the declared RPC subset |
| M4 | Public library/CLI/examples (`#58`, `#59`, `#60`) | Planned | stable API surface, toolkit CLI, supported examples |
| M5 | Release checklist and signed artifacts (`#62`) | Planned | release checklist, signed artifact flow, canonical v1 claim in `PROJECT_STATUS.md` |

## Current Execution Track

### Track A: Scope and Packaging
- Make the repo and release language toolkit-first.
- Keep experimental node surfaces outside the default release promise.
- Align onboarding, examples, and build entrypoints with the v1 target.

### Track B: Canonical Codec and Crypto
- Finish canonical transaction serialization for the supported set.
- Lock signing-domain correctness and verification vectors.
- Require strict crypto evidence on the release path.

### Track C: Live RPC Conformance
- Freeze the declared live RPC subset.
- Keep submit behavior narrow and deterministic.
- Make Gate D artifacts release-grade for the supported subset.

## Near-Term Deliverables
1. Close `#46`, `#47`, and `#61` to freeze v1 scope and eliminate local toolchain drift.
2. Land `#48`-`#50` so Gate B represents the real v1 codec surface.
3. Land `#51`-`#54` so Gate C can defend the v1 signing and verification claim.
4. Narrow and validate the live RPC subset via `#55`-`#57`.

## Not In Scope For Current Release Decision
- Mainnet validator operation.
- Full peer protocol parity.
- Full ledger sync parity.
- Consensus parity claims.
- Storage durability claims.

## Release Posture
- Current release decision remains `NO-GO` until `PROJECT_STATUS.md` criteria are met.
- Any roadmap claim is non-authoritative without linked gate evidence.
