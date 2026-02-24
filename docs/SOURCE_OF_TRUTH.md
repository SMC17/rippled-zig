# Source of Truth Index

**Purpose**: Single reference for canonical project documentation. If any other file conflicts with these, these documents are authoritative.

## Canonical Documents

| Document | Purpose |
|----------|---------|
| [`PROJECT_STATUS.md`](../PROJECT_STATUS.md) | Release decision, gate results, evidence register, risks |
| [`docs/status/ARCHITECTURE_SOT.md`](status/ARCHITECTURE_SOT.md) | Module maturity, ownership, risk per module |
| [`docs/status/AGENT_NATIVE_BACKLOG.md`](status/AGENT_NATIVE_BACKLOG.md) | Prioritized agent-native backlog (P0–P3) |
| [`docs/CONTROL_PLANE_POLICY.md`](CONTROL_PLANE_POLICY.md) | Profile policy, method allowlist, agent control surface |
| [`docs/AGENT_AUTOMATION_POLICY.md`](AGENT_AUTOMATION_POLICY.md) | Least-privilege agent automation checklist (repo/runtime/release boundaries) |
| [`docs/RELEASE_SIGNING_POLICY.md`](RELEASE_SIGNING_POLICY.md) | Signed release artifact policy and verifier procedure |
| [`docs/WASM_HOOK_EXPERIMENT.md`](WASM_HOOK_EXPERIMENT.md) | Minimal hooks-oriented WASM experiment build/run boundaries |
| [`docs/ROADMAP.md`](ROADMAP.md) | Milestones and execution track |
| [`docs/ROADMAP_TO_PARITY.md`](ROADMAP_TO_PARITY.md) | Parity claim levels and workstreams |

## CI and Gates

- **CI workflow**: `.github/workflows/quality-gates.yml`
- **Gate scripts**: `scripts/gates/` (gate_a through gate_e, gate_sim)
- **Fixture manifest**: `test_data/fixture_manifest.sha256`

## Historical Documents

The following are archived for reference only. See canonical docs above for current state.

- `HONEST_PARITY_ASSESSMENT.md`
- `PARITY_PROGRESS.md`
- `READY_FOR_LAUNCH.md`
- `READY_TO_LAUNCH.md`
- `LAUNCH_CHECKLIST.md`
- `LAUNCH_ANNOUNCEMENT.md`
