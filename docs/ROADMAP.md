# Roadmap

Status: Active roadmap for `main` as of February 19, 2026.

Canonical companion docs:
- `PROJECT_STATUS.md` (release decision + evidence register)
- `docs/status/ARCHITECTURE_SOT.md` (module maturity/ownership/risk)
- `docs/status/AGENT_NATIVE_BACKLOG.md` (prioritized backlog)

## Planning Rules
1. Gate-backed evidence before maturity claims.
2. Safety policy before autonomy expansion.
3. Deterministic contracts before broad API surface.
4. Research and production behaviors are explicitly separated.

## Milestones

| Milestone | Objective | Status | Exit Evidence |
|---|---|---|---|
| M0 | Stable quality-gate baseline (A/B/C/E + sim) | In place | `scripts/gates/gate_a.sh`, `scripts/gates/gate_b.sh`, `scripts/gates/gate_c.sh`, `scripts/gates/gate_e.sh`, `scripts/gates/gate_sim.sh` green in CI |
| M1 | Live RPC hardening + strict contracts (`account_info`, `submit`, `ping`, `ledger_current`) | In progress | `test_data/rpc_live_methods_schema.json`, `test_data/rpc_live_negative_schema.json`, `src/parity_check.zig`, `scripts/gates/gate_c.sh` |
| M2 | Control-plane policy boundary (`research` vs `production`) | In progress | profile policy tests in `src/rpc.zig` and `src/rpc_methods.zig`; method boundary checks in `gate_c` |
| M3 | Testnet conformance trend discipline (Gate D) | In progress | `scripts/gates/gate_d.sh`, `scripts/gates/gate_d_trend_merge.sh`, `artifacts/*/testnet-conformance.json` |
| M4 | Submit-path capability expansion with deterministic failure contracts | In progress | submit apply tests + Gate C fixtures for positive and negative cases |
| M5 | Agent-native protocol lab baseline | Planned | closed-loop runbook + policy docs + deterministic scenario library |
| M6 | WASM experimentation path for hooks/tooling/simulation | Planned | wasm build target, fixtures, and CI evidence job |

## Current Quarter Execution Track

### Track A: Contract and Policy Integrity
- Keep live RPC method contracts deterministic and fixture-driven.
- Expand negative-case tiers before adding broad method coverage.
- Maintain production-profile hard boundary (allowlist/denylist).

### Track B: Submit Path Deepening
- Extend minimal submit decode/validate/apply incrementally.
- Add one transaction shape at a time with deterministic errors.
- Gate each increment with schema + parity checks.

### Track C: Live Conformance
- Run Gate D regularly with testnet endpoints.
- Track latency and success-rate trends over rolling windows.
- Fail fast on contract drift between local and live behaviors.
- Operator runbook: `docs/GATE_D_OPERATOR_RUNBOOK.md` (secrets, cadence, troubleshooting).

## Near-Term Deliverables
1. Add richer submit contract tiers beyond minimal payment shape.
2. Add additional live RPC contract schemas where currently implicit.
3. Publish control-plane and RPC contract docs as machine/human references.
4. Add Gate D coverage for newly live methods as they graduate.

## Not In Scope For Current Release Decision
- Mainnet validator operation.
- Autonomous self-modifying production releases.
- Unreviewed agent writes to production profile.

## Release Posture
- Current release decision remains `NO-GO` until `PROJECT_STATUS.md` criteria are met.
- Any roadmap claim is non-authoritative without linked gate evidence.
