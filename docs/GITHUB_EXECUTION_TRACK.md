# GitHub Execution Track

Status: Active issue map for turning the current codebase into an agent-native protocol lab.

## Start Here (New Contributor Onboarding)
1. Read `README.md` for project intent and safety posture.
2. Read `PROJECT_STATUS.md` for current release decision and gate evidence.
3. Read `docs/status/ARCHITECTURE_SOT.md` for module maturity/ownership/risk.
4. Read `docs/status/AGENT_NATIVE_BACKLOG.md` for prioritized technical backlog.
5. Read `docs/CONTROL_PLANE_POLICY.md` and `docs/RPC_CONTRACT_INDEX.md` for live contracts and policy boundaries.
6. Read `docs/GITHUB_PROJECTS_SETUP.md` for project board setup and automation.

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

## Child Delivery Queue (1-3 day chunks)
Completed:
- `#13` production blocked-method contract fixtures
- `#14` control-plane transition invariant matrix tests
- `#15` Gate C strict schema contracts for `server_info` and `fee`
- `#16` Gate C `ledger` contract + deterministic negative case
- `#17` unsupported submit tx-type deterministic error contract
- `#18` submit sequence/fee boundary contracts + mutation-safety tests
- `#20` Gate D operator runbook (secrets, cadence, troubleshooting)
- `#21` deterministic simulation scenario manifest schema
- `#22` adversarial queue-pressure simulation scenario
- `#23` WASM build target and CI smoke job
- `#24` minimal hooks-oriented WASM example and docs
- `#25` signed release artifact policy and verification runbook
- `#26` least-privilege agent automation policy checklist
- `#27` parameterized consensus experiment harness skeleton

Open / active:
- `#29` production allowlist positive-case Gate C coverage matrix (good first issue)
- `#30` control-plane policy snapshot artifact for gate-backed drift detection (expert-only)
- `#31` `ledger_current` deterministic negative-case contract tiers (good first issue)
- `#32` live Gate D positive `account_info` assertions using fixture-backed account (expert-only)
- `#33` submit payment success-state contract (balance delta + sequence increment) (expert-only)
- `#34` submit payment amount/zero-value deterministic boundary errors (good first issue)
- `#35` Gate D trend summaries for `ping` / `ledger_current` latency (good first issue)
- `#36` Gate D artifact schema validation for conformance/trend outputs (expert-only)
- `#37` manifest-driven multi-scenario simulation runner (good first issue)
- `#38` hook WASM export contract checker for local/CI smoke paths (expert-only)
- `#39` Gate E artifact contract checks for security metrics/trend outputs (good first issue)
- `#40` signer key rotation drill runbook + evidence checklist (good first issue)
- `#41` extend invariant probe with `total_coins` and ledger hash validity (good first issue)
- `#42` manifest-driven consensus experiment matrix runner (expert-only)

## Triage Filters
- Starter tasks: label `good first issue`
- Advanced tasks: label `expert-only`
- Gate-sensitive work: labels `gate:c`, `gate:d`, `gate:e`, `gate:sim`

## Project Board
- Bootstrap script: `scripts/github/setup_project_board.sh`
- Automation workflow: `.github/workflows/project-intake.yml`
- Target lanes: `Now`, `Next`, `Blocked`, `good-first`

## Governance Rules
1. Every issue must link to at least one gate (`A`/`B`/`C`/`D`/`E`/`sim`) or explicit rationale if pre-gate.
2. No parity or readiness claim can be merged without evidence in `PROJECT_STATUS.md`.
3. Research-profile autonomy may mutate config; production-profile constraints are non-negotiable.
4. Any self-modifying-agent workflow must remain sandboxed and review-gated.

## Current Execution Snapshot (2026-02-24)
- Core `Now` and `Next` child queue is complete.
- Follow-on child tranche (`#29`-`#42`) is created across control-plane, RPC, submit, Gate D, simulation, WASM, security, and research tracks.
- Previous blockers `#19` and `#28` are now closed (live Gate D evidence + invariant probe/gate integration completed).
