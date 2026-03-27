# Roadmap To Parity

Status: Active parity program plan as of March 15, 2026.

This document defines how parity claims can be earned. It replaces percentage-based claims with evidence-backed gates.

## Parity Definition
Parity means reproducible behavioral alignment for declared scope, not feature-count similarity.

Declared v1 scope today:
- Live JSON-RPC subset and contracts
- Deterministic serialization/hash vectors for the supported transaction set
- Signing-hash generation and signature verification
- Negative-case error contract stability
- Testnet conformance checks for selected endpoints

Out of v1 scope:
- validator operation
- full peer compatibility
- ledger sync parity
- consensus parity
- storage durability claims

## Parity Claim Levels

| Level | Description | Required Evidence |
|---|---|---|
| P0 | Local deterministic correctness | Gate A + Gate B pass |
| P1 | Contract parity (offline) for live method subset | Gate C pass with schema fixtures |
| P2 | Live conformance parity (testnet subset) | Gate D pass with real endpoint artifacts |
| P3 | Sustained parity signal over time | rolling trend summaries for Gate C/D/E/sim |
| P4 | Security-reviewed parity candidate | Gate E trend thresholds + security review artifacts |

No claim above current evidence should appear in project docs.

## Current State (Based On Repository Evidence)
- P0: achieved for current branch workflow.
- P1: achieved for current live method subset and negative contracts.
- P2: operationally available; Gate D method coverage has expanded (`ping`, `ledger_current`) but latest live artifact evidence depends on testnet endpoint secrets.
- P3/P4: not yet achieved.

## Workstreams To Reach V1 Decision-Grade Parity

Canonical execution target:
- Epic: `#45`
- Milestone: `v1 XRPL Toolkit`
- Child issues: `#46`-`#62`

### Workstream 1: Scope Freeze and Packaging
- Align docs, examples, and build defaults with toolkit-first scope.
- Keep experimental node surfaces outside the release claim.
- Eliminate toolchain drift on the default developer path.

Exit evidence:
- `#46`, `#47`, `#61` closed
- Gate A passes on the pinned toolchain

### Workstream 2: Canonical Codec and Fixture Corpus
- Finish canonical transaction encoding for the v1-supported set.
- Pin expected bytes and digests in the fixture corpus.
- Keep Gate B tied to the real release surface.

Exit evidence:
- `#48`, `#49`, `#50` closed
- Passing `scripts/gates/gate_b.sh`

### Workstream 3: Signing and Verification Correctness
- Lock signing-domain rules for supported transactions.
- Make libsecp256k1 the mandatory strict verification path for release work.
- Expand positive and negative signature vector coverage.

Exit evidence:
- `#51`, `#52`, `#53`, `#54` closed
- Passing `scripts/gates/gate_c.sh` with strict crypto enabled

### Workstream 4: Live RPC Conformance
- Freeze the supported live RPC subset.
- Keep `submit` narrow and deterministic on the release path.
- Make Gate D artifacts decision-grade for release evidence.

Exit evidence:
- `#55`, `#56`, `#57` closed
- Passing `scripts/gates/gate_d.sh`

### Workstream 5: Public Product Surface and Release Discipline
- Expose a stable Zig library surface.
- Ship toolkit CLI commands and supported examples.
- Complete signed/reviewed release artifacts and the canonical v1 claim.

Exit evidence:
- `#58`, `#59`, `#60`, `#62` closed
- Gate A and Gate E pass on the release candidate

## Parity Claim Governance
1. Every parity statement must reference a specific gate artifact path.
2. `PROJECT_STATUS.md` is authoritative when documents conflict.
3. Historical launch or parity docs are non-authoritative without current evidence.

## Next Milestones
1. Close `#46`, `#47`, and `#61` by `2026-03-31`.
2. Close `#48`-`#54` by `2026-05-15`.
3. Close `#55`-`#57` by `2026-06-15`.
4. Close `#58`-`#60` by `2026-07-10`, then close `#62` by `2026-07-31`.
