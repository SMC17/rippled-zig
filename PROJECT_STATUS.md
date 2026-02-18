# PROJECT_STATUS

Canonical status for this repository. If any other file conflicts with this document, this document is authoritative.

Last Updated: 2026-02-18
Commit: 30fb4cb (all quality gates green; Gate E ripgrep portability fix)
Status Owner: Engineering
Scope: `main`

## Policy
- No unqualified percentage claims.
- Every technical claim must map to objective evidence.
- Experimental paths are excluded from parity claims.

## Release Decision
- Release Candidate: `NO`
- Blocking Gates:
  - Gate A (Build + Unit/Integration): `PASS`
  - Gate B (Deterministic Serialization/Hash): `PASS`
  - Gate C (Cross-Impl Parity vs rippled): `PASS`
  - Gate D (Live Testnet Conformance): `PASS` (or explicit `SKIPPED` with artifact when secrets are absent)
  - Gate E (Security/Fuzz/Static): `PASS`

## Weekly Gate Results
| Week Of | Gate A | Gate B | Gate C | Gate D | Gate E | Notes |
|---|---|---|---|---|---|---|
| 2026-02-16 | PASS | PASS | PASS | PASS | PASS | Baseline quality gates green; Gate D policy accepts explicit `skipped` artifact when secrets are unavailable. |
| 2026-02-18 | PASS | PASS | PASS | SKIPPED/POLICY | PASS | Gate B/C/E hardening merged; Gate E is now rg/grep portable; release summary green on `main`. |

## Release Decision Block
- Current Decision: `NO-GO`
- Required for `GO`:
  - Gate A/B/C/E are green on latest commit.
  - Gate D is either green (with secrets configured) or explicitly `skipped` with artifact reason.
  - No unresolved `HIGH` severity risks in the risk register.
  - `PROJECT_STATUS.md` evidence table updated with run links/commit SHAs.
- Current Blockers:
  - Production-readiness evidence is still incomplete (full network sync compatibility, exhaustive cryptographic parity, security audit).
  - Need sustained green runs over time window, not a single-cycle pass, before considering `GO`.

## Claim -> Evidence Register
| Claim ID | Claim | Scope | Evidence Type | Evidence Path | Commit SHA | Date | Reviewer | Result |
|---|---|---|---|---|---|---|---|---|
| C-001 | Toolchain pinned to Zig 0.15.1 | Gate A | CI config + tool pin | `.github/workflows/ci.yml`, `.tool-versions` | working tree | 2026-02-18 | pending | PASS |
| C-002 | Quality gates A/B/C/E are required and green in PR flow | A/B/C/E | CI workflow + run history | `https://github.com/SMC17/rippled-zig/actions/workflows/quality-gates.yml?query=branch%3Amain` | working tree | 2026-02-18 | pending | PASS |
| C-003 | Gate D supports strict live conformance and explicit skip artifact mode | Gate D | gate script + artifacts | `scripts/gates/gate_d.sh`, quality-gates artifacts | working tree | 2026-02-18 | pending | PASS |
| C-004 | Gate E enforces security checks plus fuzz budget/runtime thresholds | Gate E | gate script + checker | `scripts/gates/gate_e.sh`, `src/security_check.zig` | working tree | 2026-02-18 | pending | PASS |
| C-005 | Branch protection required-check baseline is documented for `main` | Repo Policy | branch protection runbook | `.github/BRANCH_PROTECTION_BASELINE.md` | working tree | 2026-02-18 | pending | PASS |

## Gate Definitions
### Gate A: Build + Unit/Integration
Pass Criteria:
- `scripts/gates/gate_a.sh` exits 0 on required OS matrix.
- Zig version equals `0.15.1`.

### Gate B: Deterministic Serialization/Hash
Pass Criteria:
- `scripts/gates/gate_b.sh` exits 0.
- Serialization and hash suites pass.
- Fixture SHA-256 manifest generated.

### Gate C: Cross-Implementation Parity
Pass Criteria:
- `scripts/gates/gate_c.sh` exits 0.
- RPC and real-data parity suites pass.
- Fixture-contract checks pass.

### Gate D: Live Testnet Conformance
Pass Criteria:
- `scripts/gates/gate_d.sh` exits 0 with `TESTNET_RPC_URL` and `TESTNET_WS_URL` set.
- Live ledger and fee fields validated from testnet responses.

### Gate E: Security
Pass Criteria:
- `scripts/gates/gate_e.sh` exits 0.
- Security suites pass.
- Runtime-safety scan has zero violations.

## Current Capability Matrix
| Area | State | Evidence | Included in Parity Claim |
|---|---|---|---|
| Core build | Passing in CI (A) | gate-a artifacts | NO |
| Serialization checks | Fixed-hash deterministic gate | `src/determinism_check.zig` | NO |
| RPC methods | Implemented with mixed maturity | `src/rpc_methods.zig`, `src/rpc_complete.zig` | NO |
| Peer protocol | Partial | `src/peer_protocol.zig` | NO |
| Ledger sync | Partial | `src/ledger_sync.zig` | NO |
| secp256k1 verify | Partial | `src/secp256k1*.zig` | NO |
| Testnet conformance | Wired via Gate D | `scripts/gates/gate_d.sh` | NO |
| Security scans | Wired via Gate E with strict negatives | `scripts/gates/gate_e.sh`, `src/security_check.zig` | NO |

## Known Limitations
- Local toolchain remains 0.14.1 in this workspace; local parity with CI requires upgrading to Zig 0.15.1.
- Several subsystems remain partial and require evidence-backed closure before parity claims.
- Live testnet conformance is environment-dependent and must run in controlled CI with secrets.

## Open Risks and Owners
| Risk ID | Description | Severity | Owner | Mitigation | Target Date | Status |
|---|---|---|---|---|---|---|
| R-001 | Toolchain drift breaks reproducibility | High | DevOps | enforce `.tool-versions` and CI check | 2026-02-21 | Open |
| R-002 | Unverified parity claims | High | Eng Lead | gate-based claim policy and evidence register | 2026-02-21 | Open |
| R-003 | Partial secp256k1 and sync paths | High | Crypto/Network | complete implementation + conformance tests | 2026-03-04 | Open |

## Changes Since Last Update
- Locked baseline with explicit branch-protection required-check names in `.github/BRANCH_PROTECTION_BASELINE.md`.
- Expanded Gate B deterministic vectors to cover:
  - VL length boundaries `192/193` and `12480/12481`,
  - amount-like drops encoding vector,
  - mixed-field ordering vector including `Hash256`,
  - fixed expected serialized bytes and SHA-512Half digests.
- Added Gate B vector evidence manifest:
  - `src/determinism_check.zig` now emits `VECTOR_HASH` lines for each deterministic vector,
  - `scripts/gates/gate_b.sh` now fails if vector evidence count drops below expected baseline.
- Expanded Gate C fixture parity to full snapshot checks for stable fields and cross-fixture ledger seq/hash consistency across `server_info`, `account_info`, and `current_ledger`.
- Added Gate C secp256k1 fixture evidence checks from `current_ledger.json`:
  - fixed `hash` / `SigningPubKey` / `TxnSignature` values,
  - DER parse validation of signature `r`/`s` components in `src/parity_check.zig`.
- Added Gate C negative cryptographic controls:
  - tampered DER signature must fail parse,
  - tampered pubkey/signature fixture values must fail strict mismatch controls.
- Started optional strict secp256k1 verification harness in Gate C:
  - reproducible vector with canonical signing bytes, XRPL `STX` prefix, signing hash, pubkey/signature, expected `verify=true`,
  - activated only with `GATE_C_STRICT_CRYPTO=true` (and `-Dsecp256k1=true` build).
- Tightened Gate D for richer evidence with profile metadata, explicit fail reason artifacts, endpoint health fields, and trend-point artifact output.
- Added Gate D trend consolidation script `scripts/gates/gate_d_trend_merge.sh` for rolling 7-day summaries from prior artifacts.
- Raised Gate E with profile-based fuzz budgets (`pr` vs `nightly`), seeded adversarial corpus markers, crash-free marker enforcement, and timing/budget artifacts.
- Added normalized Gate E artifact `security-metrics.json` for historical metric comparisons.

## Sign-Off
- Engineering Lead: pending
- Security Lead: pending
- Date: 2026-02-18
