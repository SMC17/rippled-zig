# GitHub Execution Track

Status: Active issue map for shipping the current codebase as a narrow v1 XRPL toolkit while keeping research tracks explicitly non-release.

## Start Here (New Contributor Onboarding)
1. Read `README.md` for project intent and safety posture.
2. Read `PROJECT_STATUS.md` for current release decision and gate evidence.
3. Read `docs/status/ARCHITECTURE_SOT.md` for module maturity/ownership/risk.
4. Read `docs/ROADMAP.md` for the active v1 release target and delivery order.
5. Read `docs/RPC_CONTRACT_INDEX.md` for the declared live subset and contracts.
6. Read `docs/GITHUB_PROJECTS_SETUP.md` for project board setup and automation.

## Issue Hierarchy
- Release Epic: defines the current v1 shipping target and success criteria.
- Research/track epics: scoped workstreams that may continue outside the v1 release promise.
- Delivery Issues: implementable chunks with tests/contracts.

## Active Issue Index
- Release epic: `#45` https://github.com/SMC17/rippled-zig/issues/45
- Milestone: `v1 XRPL Toolkit` https://github.com/SMC17/rippled-zig/milestone/1
- Research vision epic: `#4` https://github.com/SMC17/rippled-zig/issues/4
- Research/control-plane tracks: `#5`-`#12`

## V1 Delivery Queue (`#46`-`#62`)
Now:
- `#46` scope freeze: reposition repo as toolkit, not node
- `#47` build-flag split for experimental node subsystems
- `#61` toolchain enforcement and local-dev parity

Next:
- `#48` canonical field ordering for supported transaction set
- `#49` finish XRPL binary encoding for amount and variable-length fields
- `#50` define and pin canonical transaction fixture corpus
- `#51` lock signing-domain correctness for supported transactions
- `#52` promote libsecp256k1 to mandatory release verification path
- `#53` expand signature verification vector suite
- `#54` RIPEMD-160, base58, and account derivation release vectors

Then:
- `#55` narrow and harden submit to the supported transaction set
- `#56` live RPC conformance: freeze v1 method subset
- `#57` Gate D artifact hardening for release evidence
- `#58` create public library API for codec, signing, verification, and RPC parsing
- `#59` add toolkit CLI commands
- `#60` replace demo-node examples with toolkit examples
- `#62` release checklist and signed artifact workflow for v1

## Research / Historical Queue
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

## Current Execution Snapshot (2026-03-15)
- v1 release epic `#45` and milestone `v1 XRPL Toolkit` were created.
- Active delivery tranche is `#46`-`#62`, with scope freeze and toolchain parity first.
- Research tracks `#4`-`#12` remain open, but they are not the current release promise.
