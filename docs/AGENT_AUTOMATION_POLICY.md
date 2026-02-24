# Agent Automation Policy (Least Privilege)

Status: active contributor/operator policy for agent-driven development workflows.

Purpose:
- define what automation is allowed by profile today
- prevent unsafe assumptions about "full access" agent behavior
- map operational practice to current control-plane and release-gating implementation

Canonical implementation references:
- `docs/CONTROL_PLANE_POLICY.md`
- `src/rpc_methods.zig`
- `src/rpc.zig`
- `scripts/gates/gate_c.sh`
- `scripts/gates/gate_d.sh`
- `scripts/gates/gate_e.sh`
- `docs/RELEASE_SIGNING_POLICY.md`

## Policy Model

This project separates:
1. Development automation (code/test/docs/GitHub workflows)
2. Runtime control-plane operations (`agent_*` RPC methods)
3. Production-oriented release promotion

Least privilege means each layer gets only the permissions required for the task.

## Current Runtime Profiles (Maps to Control-Plane Implementation)

### `research` profile
Allowed intent:
- experimentation
- iterative config tuning
- local/testnet validation
- agent-assisted development loops

Current behavior (implemented):
- broad RPC access (subject to method implementation)
- `agent_config_set` allowed with allowlisted keys and validation

### `production` profile
Allowed intent:
- read-dominant observability and bounded operations
- status inspection and safe info methods

Current behavior (implemented):
- method allowlist enforced
- `agent_config_set` blocked by method boundary
- non-allowlisted methods return deterministic policy error
- unsafe transitions into `production` are rejected by invariant checks

See exact method boundary and invariant list in `docs/CONTROL_PLANE_POLICY.md`.

## Allowed Automation Actions By Surface

### A. Contributor/CI Automation (Repo-level)
Allowed:
- run tests and quality gates (`gate_a`, `gate_b`, `gate_c`, `gate_e`, `gate_sim`)
- run Gate D with explicit testnet secrets
- create artifacts in `artifacts/`
- open/update GitHub issues, comments, labels, project routing
- commit/push reviewed code/docs changes

Restricted:
- changing gate thresholds without documented rationale and evidence
- modifying release-signing policy and release gating in the same change without review

### B. Runtime Control Plane (`agent_*`)
Allowed in `research`:
- `agent_status`
- `agent_config_get`
- `agent_config_set` (allowlisted keys only, validated values only)

Allowed in `production`:
- `agent_status`
- `agent_config_get`
- other allowlisted info methods documented in `docs/CONTROL_PLANE_POLICY.md`

Denied in `production`:
- `agent_config_set`
- `submit`
- all non-allowlisted methods

### C. Release Promotion Automation
Allowed:
- artifact generation
- checksum/signature generation
- verification automation
- evidence collection and publishing

Denied without human approval:
- promoting unsigned artifacts as production-oriented
- bypassing Gate A/B/C/E requirements
- representing Gate D failures as passing
- changing signed artifact policy post hoc for a release candidate

## Approval Boundaries (Practical Rules)

Require explicit human approval before:
1. any production-profile policy boundary change
2. any release-signing key or verifier-path change
3. any threshold relaxation in Gate D / Gate E / Sim gates
4. any workflow change that weakens evidence collection or artifact retention
5. any mainnet-targeted operational step

Agent may proceed autonomously (within assigned scope) for:
1. docs improvements
2. deterministic fixture/schema additions
3. unit tests and local gate improvements
4. issue decomposition, project automation, backlog maintenance
5. research-profile simulation and experiment tooling

## Sandboxing and Execution Checklist

Before running an autonomous loop:
- confirm working tree status and no conflicting active developer/agent
- define issue scope (child issue number + file set when possible)
- prefer local cache env for Zig builds in sandboxed environments:
  - `ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global-cache`
  - `ZIG_LOCAL_CACHE_DIR=$PWD/.zig-cache`
- require gate-backed validation before push

When secrets are needed:
- use env vars only (`TESTNET_RPC_URL`, `TESTNET_WS_URL`)
- do not hardcode secrets or endpoints into source
- permit explicit `skipped` artifacts where policy supports it (Gate D)

## Release-Gating Checklist (Before “Production-Oriented” Claims)

Use this with `docs/RELEASE_SIGNING_POLICY.md` and `PROJECT_STATUS.md`.

- Gate A/B/C/E green on candidate commit
- Gate D green or explicit policy skip artifact
- required release artifacts present
- `SHA256SUMS.sig` present and verifiable
- `PROJECT_STATUS.md` evidence updated
- no unresolved high-severity security blockers for the release claim

## Contributor Onboarding Checklist

New contributors using agents should:
1. Read `PROJECT_STATUS.md` (current reality)
2. Read `docs/CONTROL_PLANE_POLICY.md` (runtime method boundaries)
3. Read this file (`docs/AGENT_AUTOMATION_POLICY.md`)
4. Run local gates before pushing
5. Treat `research` and `production` as different safety domains

## Non-Goals (Current Project State)

This policy does not authorize:
- autonomous production validator governance decisions
- self-modifying production deployments
- unreviewed release promotion
- bypassing signed artifact controls
