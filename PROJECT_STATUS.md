# PROJECT_STATUS

Canonical status for this repository. If any other file conflicts with this document, this document is authoritative.

Last Updated: 2026-03-26
Commit: working tree (v1 toolkit repositioning)
Status Owner: Engineering
Scope: `main`

---

## Policy

- No unqualified percentage claims.
- Every technical claim must map to objective, reproducible evidence.
- Experimental modules are excluded from all release claims.
- Gate results older than 14 days without a follow-up run are considered stale.

---

## V1 Release Claim

**rippled-zig v1** is a Zig XRPL Protocol Toolkit providing:

1. **Canonical transaction encoding** for Payment, AccountSet, OfferCreate, and OfferCancel
2. **Signing-hash generation** (SHA-512Half with XRPL `STX` prefix domain separation) and **signature verification** (secp256k1 via libsecp256k1, Ed25519 via Zig standard library)
3. **Selected live RPC conformance** for `server_info`, `fee`, `ledger`, `ledger_current`, `account_info`, and `submit` (narrow transaction subset)
4. **Stable Zig library and CLI surface** built and tested against Zig 0.14.1
5. **Signed release evidence** with all gates green and artifact chain intact

### Explicitly Outside V1

- Validator or full node operation
- P2P overlay / peer protocol parity
- Full ledger sync
- Consensus participation or parity
- Storage durability guarantees
- Agent control surfaces as part of the release promise

---

## Release Decision

| Field | Value |
|---|---|
| Release Candidate | **NO** |
| Decision | **NO-GO** |
| Decision Date | Pending |
| Decision Owner | Engineering Lead |

### Gate Status (Current)

| Gate | Name | Status | Evidence |
|---|---|---|---|
| A | Build + Unit/Integration | **PASS** | `scripts/gates/gate_a.sh` exit 0; CI workflow artifacts |
| B | Deterministic Serialization/Hash | **PASS** | `scripts/gates/gate_b.sh` exit 0; fixture SHA-256 manifest |
| C | Cross-Impl Parity (vs rippled) | **PASS** | `scripts/gates/gate_c.sh` exit 0; strict crypto with `GATE_C_STRICT_CRYPTO=true` |
| D | Live Testnet Conformance | **PASS** | `scripts/gates/gate_d.sh` exit 0; or explicit `SKIPPED` artifact when secrets absent |
| E | Security / Fuzz / Static | **PASS** | `scripts/gates/gate_e.sh` exit 0; security-metrics.json |
| Sim | Deterministic Local Cluster | **PASS** | `scripts/gates/gate_sim.sh` exit 0; simulation-summary.json |

### Required for GO

- [ ] Gates A/B/C/E green on tagged release commit
- [ ] Gate D green (or explicit skip with artifact) on tagged release commit
- [ ] Canonical codec complete for declared v1 transaction set (Payment, AccountSet, OfferCreate, OfferCancel)
- [ ] secp256k1 and Ed25519 verification paths exercised by Gate C strict vectors
- [ ] Signed release artifact policy satisfied (`SHA256SUMS.sig` + verifier path)
- [ ] No unresolved HIGH severity risks in risk register
- [ ] Sustained green gate runs across minimum 4-week window
- [ ] This document updated with final evidence table, commit SHAs, and run links

### Current Blockers

- Canonical codec and signing/verification surfaces not yet complete for declared v1 transaction set
- Repository messaging repositioning in progress (#46)
- Production-readiness evidence incomplete (audit, sustained soak)
- Need sustained green runs over time window, not single-cycle pass

---

## Claim-to-Evidence Register

| ID | Claim | Scope | Evidence Type | Evidence Path | Status |
|---|---|---|---|---|---|
| C-001 | Toolchain pinned to Zig 0.14.1 | Gate A | CI config + tool pin | `.github/workflows/ci.yml`, `.tool-versions` | PASS |
| C-002 | Gates A/B/C/E required and green in PR flow | A/B/C/E | CI workflow + run history | `.github/workflows/quality-gates.yml` | PASS |
| C-003 | Gate D supports strict live conformance and explicit skip | Gate D | Gate script + artifacts | `scripts/gates/gate_d.sh` | PASS |
| C-004 | Gate E enforces security checks and fuzz budget thresholds | Gate E | Gate script + metrics | `scripts/gates/gate_e.sh`, `src/security_check.zig` | PASS |
| C-005 | Branch protection baseline documented for `main` | Repo Policy | Branch protection runbook | `.github/BRANCH_PROTECTION_BASELINE.md` | PASS |
| C-006 | Signed release artifact policy documented | Release Security | Policy + runbook + workflow | `docs/RELEASE_SIGNING_POLICY.md`, `.github/workflows/ci.yml` | PASS |
| C-007 | Canonical encoding covers Payment, AccountSet, OfferCreate, OfferCancel | Gate B | Deterministic vectors + fixture manifest | `src/canonical_tx.zig`, `src/determinism_check.zig` | IN PROGRESS |
| C-008 | secp256k1 strict verification with positive and negative vectors | Gate C | Strict crypto harness | `src/parity_check.zig`, `scripts/gates/gate_c.sh` | PASS |
| C-009 | Ed25519 signing and verification | Crypto | Unit tests | `src/crypto.zig` | IN PROGRESS |
| C-010 | Live RPC conformance for declared 6-method subset | Gate D | Live endpoint validation | `scripts/gates/gate_d.sh`, trend artifacts | PASS |
| C-011 | Repository positioned as toolkit, not node | Docs | README.md, PROJECT_STATUS.md | This document, `README.md` | IN PROGRESS |

---

## Gate Definitions

### Gate A: Build + Unit/Integration

**Pass criteria:**
- `scripts/gates/gate_a.sh` exits 0 on required OS matrix
- Zig version equals `0.14.1`

### Gate B: Deterministic Serialization/Hash

**Pass criteria:**
- `scripts/gates/gate_b.sh` exits 0
- Serialization and hash suites pass for all declared transaction types
- Fixture SHA-256 manifest generated and matches committed baseline (`test_data/fixture_manifest.sha256`)
- Vector hash evidence emitted for each deterministic vector (VL boundaries, drops encoding, mixed-field ordering)

### Gate C: Cross-Implementation Parity

**Pass criteria:**
- `scripts/gates/gate_c.sh` exits 0
- RPC fixture parity checks pass (stable fields, cross-fixture consistency)
- secp256k1 strict verification with `GATE_C_STRICT_CRYPTO=true`: 3 positive vectors, 3 negative vectors
- Signing-domain correctness: `SHA512Half(STX || canonical)` equals expected signing hash; regression checks against wrong-prefix and body-only hashes

### Gate D: Live Testnet Conformance

**Pass criteria:**
- `scripts/gates/gate_d.sh` exits 0 with `TESTNET_RPC_URL` and `TESTNET_WS_URL` configured
- Live `server_info`, `fee`, `ledger`, `ledger_current`, `account_info` fields validated
- Trend success-rate floor and p95 latency ceiling enforced from 7-day rolling summary
- Operator runbook: `docs/GATE_D_OPERATOR_RUNBOOK.md`

### Gate E: Security

**Pass criteria:**
- `scripts/gates/gate_e.sh` exits 0
- Security suites pass with zero runtime-safety violations
- Fuzz budget enforcement with profile-based thresholds (`pr` vs `nightly`)
- Crash-free marker enforcement
- Trend success-rate, crash-free-rate, p95 runtime, and avg fuzz budget floors from 7-day summary

### Sim: Deterministic Local Cluster

**Pass criteria:**
- `scripts/gates/gate_sim.sh` exits 0
- Profile-based thresholds enforced (`pr` vs `nightly`)
- 7-day trend drift checks for success-rate, p95 latency, avg nodes

---

## Weekly Gate Results

| Week Of | A | B | C | D | E | Sim | Notes |
|---|---|---|---|---|---|---|---|
| 2026-02-16 | PASS | PASS | PASS | PASS | PASS | PASS | Baseline quality gates green |
| 2026-02-18 | PASS | PASS | PASS | SKIP | PASS | PASS | Gate D accepts explicit skip artifact |

---

## Capability Matrix

| Area | V1 Scope | State | Evidence Source |
|---|---|---|---|
| Canonical transaction encoding | Payment, AccountSet, OfferCreate, OfferCancel | In progress | `src/canonical_tx.zig`, Gate B |
| Signing-hash generation | SHA-512Half + STX prefix | Implemented | `src/crypto.zig`, Gate B/C |
| secp256k1 verification | Strict external path via libsecp256k1 | Implemented | `src/secp256k1*.zig`, Gate C |
| Ed25519 verification | Via Zig std library | In progress | `src/crypto.zig` |
| Base58Check encoding | Address encode/decode | Implemented | `src/base58.zig` |
| RPC: server_info | Live + fixture | Implemented | Gate D, Gate C |
| RPC: fee | Live + fixture | Implemented | Gate D, Gate C |
| RPC: ledger | Live + fixture | Implemented | Gate D, Gate C |
| RPC: ledger_current | Live + fixture | Implemented | Gate D, Gate C |
| RPC: account_info | Live + fixture | Implemented | Gate D, Gate C |
| RPC: submit | Narrow transaction subset | Implemented | Gate D, Gate C |
| CLI surface | Build, test, run, gates | Stable | Gate A |

### Not in V1 Scope

| Area | State | Notes |
|---|---|---|
| Peer protocol | Experimental | `src/peer_protocol.zig` -- research only |
| Ledger sync | Experimental | `src/ledger_sync.zig` -- research only |
| Consensus | Experimental | `src/consensus.zig` -- research only |
| Storage | Experimental | `src/storage.zig`, `src/database.zig` -- research only |
| Validator operation | Experimental | Not part of any release claim |

---

## Open Risks

| ID | Description | Severity | Owner | Mitigation | Target | Status |
|---|---|---|---|---|---|---|
| R-001 | Toolchain drift breaks reproducibility | High | DevOps | Enforce `.tool-versions` and CI check | 2026-03-31 | Open |
| R-002 | Repo messaging overstates partial node surfaces | High | Eng Lead | Close #46; update README, PROJECT_STATUS, examples | 2026-03-31 | In Progress |
| R-003 | Partial codec/crypto paths block release claim | High | Crypto/Protocol | Close #48-#54 with gate evidence | 2026-05-15 | Open |
| R-004 | Live RPC subset and release packaging incomplete | High | API/Release | Close #55-#62 with gate evidence | 2026-07-31 | Open |

---

## V1 Execution Track

**Milestone**: `v1 XRPL Toolkit`
**Epic**: [#45](https://github.com/SMC17/rippled-zig/issues/45)
**Child issues**: #46-#62

| Tranche | Issues | Target | Description |
|---|---|---|---|
| 1. Scope freeze | #46, #47, #61 | 2026-03-31 | Reposition docs, prune examples, lock toolchain |
| 2. Codec + crypto | #48-#54 | 2026-05-15 | Canonical encoding and verification for declared tx set |
| 3. Live + RPC | #55-#57 | 2026-06-15 | RPC subset hardening, live conformance evidence |
| 4. Public surface | #58-#60 | 2026-07-10 | API/CLI stability, examples, packaging |
| 5. Release | #62 | 2026-07-31 | Signed artifacts, release checklist, final evidence |

---

## Known Limitations

- Several codec and verification paths require evidence-backed closure before release
- Live testnet conformance is environment-dependent; must run in controlled CI with secrets
- Experimental modules remain in the repo but carry no correctness claims
- No independent security audit has been performed
- No long-horizon soak evidence exists yet

---

## Sign-Off

| Role | Name | Date | Decision |
|---|---|---|---|
| Engineering Lead | Pending | -- | -- |
| Security Lead | Pending | -- | -- |

---

## Changes Since Last Update

- 2026-03-26: Repositioned README.md and PROJECT_STATUS.md as toolkit (not node) per #46
  - Rewrote README.md with toolkit positioning, supported surface tables, architecture diagram, gate badges
  - Rewrote PROJECT_STATUS.md with exact v1 release claim, evidence register, capability matrix
  - Added claims C-007 through C-011 to evidence register
  - Restructured gate results table to include Sim column
  - Separated capability matrix into v1 scope and not-in-scope sections
