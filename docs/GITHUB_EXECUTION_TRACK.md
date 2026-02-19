# GitHub Execution Track

Status: Active issue map for turning the current codebase into an agent-native protocol lab.

## Start Here (New Contributor Onboarding)
1. Read `README.md` for project intent and safety posture.
2. Read `PROJECT_STATUS.md` for current release decision and gate evidence.
3. Read `docs/status/ARCHITECTURE_SOT.md` for module maturity/ownership/risk.
4. Read `docs/status/AGENT_NATIVE_BACKLOG.md` for prioritized technical backlog.
5. Read `docs/CONTROL_PLANE_POLICY.md` and `docs/RPC_CONTRACT_INDEX.md` for live contracts and policy boundaries.

## Issue Hierarchy
- Vision Epic: defines target end-state and success criteria.
- Track Epics: scoped workstreams with gate-linked acceptance.
- Delivery Issues: implementable chunks with tests/contracts.

## Active Issue Index
- Vision Epic: `#4` https://github.com/SMC17/rippled-zig/issues/4
- Track: control plane and policy boundary: `#5` https://github.com/SMC17/rippled-zig/issues/5
- Track: live RPC contracts and negative tiers: `#6` https://github.com/SMC17/rippled-zig/issues/6
- Track: submit path fidelity expansion: `#7` https://github.com/SMC17/rippled-zig/issues/7
- Track: Gate D live conformance expansion: `#8` https://github.com/SMC17/rippled-zig/issues/8
- Track: deterministic simulation scenario library: `#9` https://github.com/SMC17/rippled-zig/issues/9
- Track: WASM hooks/tooling path: `#10` https://github.com/SMC17/rippled-zig/issues/10
- Track: security and signed release chain: `#11` https://github.com/SMC17/rippled-zig/issues/11
- Track: consensus/formal-invariant research sandbox: `#12` https://github.com/SMC17/rippled-zig/issues/12

## Governance Rules
1. Every issue must link to at least one gate (`A`/`B`/`C`/`D`/`E`/`sim`) or explicit rationale if pre-gate.
2. No parity or readiness claim can be merged without evidence in `PROJECT_STATUS.md`.
3. Research-profile autonomy may mutate config; production-profile constraints are non-negotiable.
4. Any self-modifying-agent workflow must remain sandboxed and review-gated.
