# Roadmap To Parity

Status: Active parity program plan as of February 24, 2026.

This document defines how parity claims can be earned. It replaces percentage-based claims with evidence-backed gates.

## Parity Definition
Parity means reproducible behavioral alignment for declared scope, not feature-count similarity.

Declared scope today:
- Live JSON-RPC subset and contracts
- Deterministic serialization/hash vectors
- Negative-case error contract stability
- Testnet conformance checks for selected endpoints

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

## Workstreams To Reach Decision-Grade Parity

### Workstream 1: RPC Contract Expansion
- Expand strict schemas for each newly live method.
- Add deterministic negative contracts before broadening method behavior.
- Keep fixture manifest pinned and reviewed.

Exit evidence:
- Updated `test_data/rpc_live_methods_schema.json` and `test_data/rpc_live_negative_schema.json`
- Passing `scripts/gates/gate_c.sh`

### Workstream 2: Submit Path Fidelity
- Extend minimal submit decoding/validation/apply coverage by transaction shape.
- Add exact deterministic error mapping for each fail class.

Exit evidence:
- unit tests in `src/rpc.zig` / `src/rpc_methods.zig`
- Gate C fixture and schema checks for new cases

### Workstream 3: Live Testnet Conformance
- Keep Gate D strict on endpoint health, status/error contracts, and latency thresholds.
- Add live checks for newly promoted methods.
- Maintain operator runbook for secrets/cadence/troubleshooting (`docs/GATE_D_OPERATOR_RUNBOOK.md`).

Exit evidence:
- `scripts/gates/gate_d.sh` pass artifacts
- `trend-summary-7d.json` within thresholds

### Workstream 4: Policy and Safety
- Preserve hard boundary between research and production profiles.
- Block unsafe profile transitions and runtime config drift in production.

Exit evidence:
- policy tests in `src/rpc.zig` and `src/rpc_methods.zig`
- deterministic policy contract checks in Gate C

### Workstream 5: Security and Supply Chain
- Maintain Gate E checks and trend thresholds.
- Require signed/reviewed release chain for production-oriented claims.

Exit evidence:
- `scripts/gates/gate_e.sh` pass artifacts
- policy and provenance documentation

## Parity Claim Governance
1. Every parity statement must reference a specific gate artifact path.
2. `PROJECT_STATUS.md` is authoritative when documents conflict.
3. Historical launch or parity docs are non-authoritative without current evidence.

## Next Milestones
1. Close live Gate D evidence gap for `ping` / `ledger_current` with real testnet artifacts (`#19`).
2. Expand research-sandbox invariants and simulation evidence (`#28`).
3. Achieve sustained 7-day trend thresholds with no high-severity open risks.
4. Produce review packet for security and release decision sign-off.
