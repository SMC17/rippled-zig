# PROJECT_STATUS

Canonical status for this repository. If any other file conflicts with this document, this document is authoritative.

Last Updated: 2026-02-17
Commit: 7561a49 (baseline before this hardening pass)
Status Owner: Engineering
Scope: `main`

## Policy
- No unqualified percentage claims.
- Every technical claim must map to objective evidence.
- Experimental paths are excluded from parity claims.

## Release Decision
- Release Candidate: `NO`
- Blocking Gates:
  - Gate A (Build + Unit/Integration): `FAIL`
  - Gate B (Deterministic Serialization/Hash): `NOT RUN`
  - Gate C (Cross-Impl Parity vs rippled): `NOT RUN`
  - Gate D (Live Testnet Conformance): `NOT RUN`
  - Gate E (Security/Fuzz/Static): `NOT RUN`

## Claim -> Evidence Register
| Claim ID | Claim | Scope | Evidence Type | Evidence Path | Commit SHA | Date | Reviewer | Result |
|---|---|---|---|---|---|---|---|---|
| C-001 | Toolchain must be Zig 0.15.1 | Gate A | CI config + tool pin | `.github/workflows/ci.yml`, `.tool-versions` | working tree | 2026-02-17 | pending | PASS |
| C-002 | Local gate baseline currently fails | Gate A | build output | `artifacts/gate-a/failure.txt` (expected after running gate) | working tree | 2026-02-17 | pending | FAIL |
| C-003 | Quality gate workflow is executable without TODO stubs | Gates A-E | workflow + scripts | `.github/workflows/quality-gates.yml`, `scripts/gates/` | working tree | 2026-02-17 | pending | PASS |

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
| Core build | Failing locally on wrong toolchain | `zig version`, build output | NO |
| Serialization tests | Present and wired in Gate B | `tests/protocol/serialization_comprehensive.zig` | NO |
| RPC methods | Implemented with mixed maturity | `src/rpc_methods.zig`, `src/rpc_complete.zig` | NO |
| Peer protocol | Partial | `src/peer_protocol.zig` | NO |
| Ledger sync | Partial | `src/ledger_sync.zig` | NO |
| secp256k1 verify | Partial | `src/secp256k1*.zig` | NO |
| Testnet conformance | Wired via Gate D | `scripts/gates/gate_d.sh` | NO |
| Security scans | Wired via Gate E | `scripts/gates/gate_e.sh` | NO |

## Known Limitations
- Build/test reproducibility depends on Zig 0.15.1; local 0.14.1 is incompatible.
- Several subsystems remain partial and require evidence-backed closure before parity claims.
- Live testnet conformance is environment-dependent and must run in controlled CI with secrets.

## Open Risks and Owners
| Risk ID | Description | Severity | Owner | Mitigation | Target Date | Status |
|---|---|---|---|---|---|---|
| R-001 | Toolchain drift breaks reproducibility | High | DevOps | enforce `.tool-versions` and CI check | 2026-02-18 | Open |
| R-002 | Unverified parity claims | High | Eng Lead | gate-based claim policy and evidence register | 2026-02-21 | Open |
| R-003 | Partial secp256k1 and sync paths | High | Crypto/Network | complete implementation + conformance tests | 2026-02-28 | Open |

## Changes Since Last Update
- Added executable quality gate workflow: `.github/workflows/quality-gates.yml`.
- Added concrete gate runners: `scripts/gates/gate_a.sh` through `scripts/gates/gate_e.sh`.
- Added toolchain pin: `.tool-versions`.

## Sign-Off
- Engineering Lead: pending
- Security Lead: pending
- Date: 2026-02-17
