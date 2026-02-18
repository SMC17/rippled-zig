# 14-Day Task Board (Owner-Ready)

Scope: move from optimistic parity claims to evidence-backed quality gates.
Definition of done for this board: all Gate A-E jobs pass on `main` for 5 consecutive daily runs.

## Team Roles
- ENG-LEAD: engineering lead
- PROTOCOL-ENG: protocol/core engineer
- NETWORK-ENG: peer protocol + sync engineer
- CRYPTO-ENG: cryptography engineer
- QA-ENG: test/conformance engineer
- SEC-ENG: security engineer
- DEVOPS: CI/CD + release
- TECH-WRITER: docs/status owner

## Priority Legend
- P0: release blocker
- P1: critical quality
- P2: important but can follow

## Day-by-Day Tickets

### Day 1
- ID: D1-T1
- Title: Pin Zig Toolchain Across Local and CI
- Owner: DEVOPS
- Priority: P0
- Deliverables:
  - Add toolchain pin file (`.tool-versions` or equivalent) with `zig 0.15.1`
  - Ensure CI and docs reference same version
- Acceptance Criteria:
  - `zig version` in CI logs is exactly `0.15.1`
  - `README.md` and `GETTING_STARTED.md` match
- Evidence:
  - CI run URL + commit SHA + screenshot/log excerpt

- ID: D1-T2
- Title: Create Single Source of Truth Status Doc
- Owner: TECH-WRITER
- Priority: P0
- Deliverables:
  - Introduce `PROJECT_STATUS.md` using strict evidence template
  - Mark conflicting legacy docs as non-canonical
- Acceptance Criteria:
  - No unqualified parity percentages in canonical doc
  - Every claim has linked evidence
- Evidence:
  - PR URL + diff + reviewer sign-off

### Day 2
- ID: D2-T1
- Title: Make Build/Test Baseline Green
- Owner: ENG-LEAD
- Priority: P0
- Deliverables:
  - Fix compile/runtime blockers in core modules
  - `zig build`, `zig build test`, `zig fmt --check .` passing
- Acceptance Criteria:
  - Gate A passes on both `ubuntu-latest` and `macos-latest`
- Evidence:
  - CI artifacts: test report + build summary

- ID: D2-T2
- Title: Add Quality Gate Workflow (A-E skeleton)
- Owner: DEVOPS
- Priority: P0
- Deliverables:
  - Add dedicated workflow with hard job dependencies
  - Add artifact retention + run summary
- Acceptance Criteria:
  - Failing gate blocks merge via required checks
- Evidence:
  - Branch protection screenshot + CI run URL

### Day 3
- ID: D3-T1
- Title: Serialization Golden Tests (Determinism)
- Owner: QA-ENG
- Priority: P0
- Deliverables:
  - Add golden vectors for canonical serialization and tx hash
  - Add deterministic replay tests
- Acceptance Criteria:
  - Same input -> byte-identical output across runs/platforms
- Evidence:
  - `artifacts/gate-b/golden-report.txt`

- ID: D3-T2
- Title: Hash Validation Against Reference Vectors
- Owner: PROTOCOL-ENG
- Priority: P0
- Deliverables:
  - Validate ledger hash and tx hash against known fixtures
- Acceptance Criteria:
  - 100% pass on fixture set
- Evidence:
  - Test log + fixture manifest hash

### Day 4
- ID: D4-T1
- Title: Remove Placeholder RPC Responses (Batch 1)
- Owner: PROTOCOL-ENG
- Priority: P1
- Deliverables:
  - Replace placeholder/mock responses in high-traffic RPCs
- Acceptance Criteria:
  - Contract tests assert real state-backed fields
- Evidence:
  - RPC contract test report

- ID: D4-T2
- Title: Submit Path Correctness
- Owner: PROTOCOL-ENG
- Priority: P1
- Deliverables:
  - Implement submit deserialize/validate/apply pipeline
- Acceptance Criteria:
  - `submit` rejects malformed input and produces correct error codes
- Evidence:
  - Integration tests with positive/negative cases

### Day 5
- ID: D5-T1
- Title: secp256k1 Verification Path Hardening
- Owner: CRYPTO-ENG
- Priority: P0
- Deliverables:
  - Ensure deterministic signature verification behavior
  - Add explicit feature flag behavior for environments without libsecp256k1
- Acceptance Criteria:
  - 100+ secp256k1 vectors pass
- Evidence:
  - `artifacts/gate-c/secp256k1-report.txt`

- ID: D5-T2
- Title: Canonical Tx Serialization Completion
- Owner: PROTOCOL-ENG
- Priority: P1
- Deliverables:
  - Implement missing IOU/signer serialization paths
- Acceptance Criteria:
  - Golden tests cover all implemented tx types
- Evidence:
  - Test matrix report

### Day 6
- ID: D6-T1
- Title: Peer Handshake Compatibility
- Owner: NETWORK-ENG
- Priority: P0
- Deliverables:
  - Replace placeholder hello fields with live ledger state
  - Validate protocol/network IDs and error paths
- Acceptance Criteria:
  - Handshake tests pass with strict parser checks
- Evidence:
  - `artifacts/gate-d/peer-handshake-report.txt`

- ID: D6-T2
- Title: Message Parser Robustness
- Owner: NETWORK-ENG
- Priority: P1
- Deliverables:
  - Handle malformed frames, truncation, oversized payloads safely
- Acceptance Criteria:
  - Adversarial parser tests pass
- Evidence:
  - security test logs

### Day 7
- ID: D7-T1
- Title: Ledger Sync Apply Path
- Owner: NETWORK-ENG
- Priority: P0
- Deliverables:
  - Apply validated ledgers into ledger manager/state
- Acceptance Criteria:
  - Sync progresses and updates canonical head
- Evidence:
  - `artifacts/gate-d/ledger-sync-report.txt`

- ID: D7-T2
- Title: Parent/State Hash Validation in Sync
- Owner: PROTOCOL-ENG
- Priority: P0
- Deliverables:
  - Enforce parent hash and state hash checks (no soft-pass warnings)
- Acceptance Criteria:
  - Hash mismatch is hard fail
- Evidence:
  - negative test cases with expected rejection

### Day 8
- ID: D8-T1
- Title: Cross-Implementation Parity Harness (rippled)
- Owner: QA-ENG
- Priority: P0
- Deliverables:
  - Build test harness comparing outputs vs reference implementation
- Acceptance Criteria:
  - parity report generated for selected method/tx set
- Evidence:
  - `artifacts/gate-c/parity-report.json`

- ID: D8-T2
- Title: RPC Contract Baseline
- Owner: QA-ENG
- Priority: P1
- Deliverables:
  - Define request/response contract tests for implemented RPC methods
- Acceptance Criteria:
  - no placeholder fields in methods marked production
- Evidence:
  - contract report + schema snapshot

### Day 9
- ID: D9-T1
- Title: Live Testnet Conformance Runner
- Owner: QA-ENG
- Priority: P0
- Deliverables:
  - Optional/manual CI job using secrets to validate against testnet
- Acceptance Criteria:
  - report includes hash/signature/ledger checks with pass/fail totals
- Evidence:
  - `artifacts/gate-d/testnet-conformance.json`

- ID: D9-T2
- Title: Network Reconnect and Session Stability
- Owner: NETWORK-ENG
- Priority: P1
- Deliverables:
  - reconnection logic + backoff + state recovery tests
- Acceptance Criteria:
  - survives fault injection scenarios
- Evidence:
  - soak test trace excerpts

### Day 10
- ID: D10-T1
- Title: Fuzz Targets for Parsers and RPC
- Owner: SEC-ENG
- Priority: P0
- Deliverables:
  - fuzz targets for peer messages, serialization, rpc handlers
- Acceptance Criteria:
  - minimum fuzz time budget completed with zero crashes
- Evidence:
  - `artifacts/gate-e/fuzz-summary.txt`

- ID: D10-T2
- Title: Security Static Checks and Threat Notes
- Owner: SEC-ENG
- Priority: P1
- Deliverables:
  - static checks + threat checklist with unresolved risks
- Acceptance Criteria:
  - critical findings addressed or explicitly accepted
- Evidence:
  - `artifacts/gate-e/security-review.md`

### Day 11
- ID: D11-T1
- Title: 24h Soak Test Pipeline
- Owner: DEVOPS
- Priority: P1
- Deliverables:
  - scheduled long-run job with memory/FD/error-rate metrics
- Acceptance Criteria:
  - no crash/leak threshold violations
- Evidence:
  - soak artifact bundle

- ID: D11-T2
- Title: Metrics and Regression Thresholds
- Owner: ENG-LEAD
- Priority: P1
- Deliverables:
  - define benchmark floors and regression budgets
- Acceptance Criteria:
  - gate fails on threshold breach
- Evidence:
  - benchmark trend report

### Day 12
- ID: D12-T1
- Title: Documentation Reconciliation Sweep
- Owner: TECH-WRITER
- Priority: P0
- Deliverables:
  - align `README.md`, `STATUS.md`, launch docs with measured reality
- Acceptance Criteria:
  - no contradictory claims across canonical docs
- Evidence:
  - docs consistency checklist

- ID: D12-T2
- Title: Mark Experimental vs Production-Candidate Surfaces
- Owner: ENG-LEAD
- Priority: P1
- Deliverables:
  - clear labels in code/docs for unsupported paths
- Acceptance Criteria:
  - every placeholder path labeled and excluded from parity gate
- Evidence:
  - grep report + docs links

### Day 13
- ID: D13-T1
- Title: Release Readiness Review (No v1.0 unless gates pass)
- Owner: ENG-LEAD
- Priority: P0
- Deliverables:
  - signed checklist from engineering + security
- Acceptance Criteria:
  - all mandatory gate runs green
- Evidence:
  - release review record

- ID: D13-T2
- Title: Backlog Carry-Over Prioritization
- Owner: PM/ENG-LEAD
- Priority: P2
- Deliverables:
  - prioritized post-14-day backlog with risk tags
- Acceptance Criteria:
  - owner and due date for each open item
- Evidence:
  - board snapshot

### Day 14
- ID: D14-T1
- Title: Final Quality Gate Burn-In
- Owner: DEVOPS
- Priority: P0
- Deliverables:
  - 5 consecutive daily green runs on `main`
- Acceptance Criteria:
  - zero gate failures in burn-in window
- Evidence:
  - run list + timestamps

- ID: D14-T2
- Title: Publish Evidence-Based Status Snapshot
- Owner: TECH-WRITER
- Priority: P0
- Deliverables:
  - updated `PROJECT_STATUS.md` with all evidence links
- Acceptance Criteria:
  - reviewer confirms every claim has artifact proof
- Evidence:
  - merge commit SHA + review approval

## Weekly Milestones
- Week 1 Exit Criteria:
  - Gates A and B required green
  - Major placeholders removed or explicitly marked experimental
- Week 2 Exit Criteria:
  - Gates C, D, E producing reliable reports
  - release decision based on gate outcomes only
