# Architecture Source Of Truth (SOT)

Date: 2026-02-19
Scope: current `main` workspace

## Ownership Model
- Protocol Core Owner: ledger/consensus/serialization/hash correctness
- Networking Owner: p2p peer protocol, sync, live data ingress
- API/Control Plane Owner: rpc server, rpc methods, agent control surface
- Security/Quality Owner: secp paths, fuzz/static checks, gate policy
- Tooling/Simulation Owner: deterministic cluster harness, trend gates, artifacts

## Module Maturity + Risk
| Module | Maturity | Owner | Primary Risk | Notes |
|---|---|---|---|---|
| `src/main.zig` | Medium | Protocol Core | Demo-path runtime only | Coordinator initialized; long-running services not fully threaded. |
| `src/ledger.zig` | Medium | Protocol Core | simplified state hash path | Deterministic hash path present; full XRPL state tree not complete. |
| `src/consensus.zig` | Medium | Protocol Core | incomplete real-network behavior | State machine exists; production consensus behavior still partial. |
| `src/transaction.zig` | Medium | Protocol Core | partial tx coverage | Core validation exists; expanded offer tx coverage added in this tranche. |
| `src/rpc_methods.zig` | Medium-High | API/Control Plane | shape drift vs parity contracts | Strong fixture/schema checks; still evolving method completeness. |
| `src/rpc.zig` | Medium | API/Control Plane | request parsing robustness | Hardened in this tranche (path/body/method validation). |
| `src/network.zig` | Low-Medium | Networking | live P2P compatibility | Framework exists; full peer protocol interoperability incomplete. |
| `src/peer_protocol.zig` | Medium | Networking | wire compatibility edge cases | Substantial structure; needs sustained conformance evidence. |
| `src/ledger_sync.zig` | Low-Medium | Networking | sync correctness/perf under churn | Partial implementation. |
| `src/storage.zig` | Medium | Protocol Core | persistence guarantees | Local persistence abstractions; long-run durability evidence needed. |
| `src/secp256k1*.zig` | Medium | Security/Quality | strict verification coverage | Strict Gate C vectors exist; still marked partial in status matrix. |
| `src/security_check.zig` | High | Security/Quality | drift in runtime/static checks | Gate E enforced with trend thresholds. |
| `src/parity_check.zig` | High | Security/Quality | false confidence from weak fixtures | Expanded contract checks; schema checks now include agent config. |
| `scripts/sim/*` | High | Tooling/Simulation | model-realism gap | Deterministic cluster and trend gating in place. |

## Current Control Plane Surface
- Read telemetry: `agent_status`
- Read config: `agent_config_get`
- Allowlisted writes: `agent_config_set`
- Mutable keys: `max_peers`, `fee_multiplier`, `strict_crypto_required`, `allow_unl_updates`

## Modular Layout
Logical package grouping (use `@import("modules.zig")` for clean imports):
- **Consensus**: consensus.zig
- **Ledger**: ledger.zig, transaction.zig, types.zig
- **API**: rpc.zig, rpc_methods.zig
- **Network**: network.zig, peer_protocol.zig, peer_wire.zig, ledger_sync.zig, websocket.zig
- **Security**: security.zig, security_check.zig, parity_check.zig

## Hard Limits (Design Constraints)
- Governance/accountability remains human-owned; autonomous changes require review/sign-off.
- No unreviewed self-modifying path to production branches/releases.
- Full-access agents require sandboxing, least-privilege, and signed artifact/release controls.
