# Agent-Native Protocol Lab Backlog

Date: 2026-02-19
Target: move from educational daemon to agent-native protocol lab with safety constraints.

## Prioritization Rules
1. Anything tied to gate evidence and safety policy comes first.
2. Close live-path correctness gaps before adding broad feature surface.
3. Prefer deterministic/offline contracts for agent loops, then live conformance.

## P0 (Now)
| Item | Outcome | Evidence |
|---|---|---|
| RPC live-path hardening | safer JSON-RPC request handling for automation clients | unit tests + `gate-a` |
| Agent control schema contracts | prevent API drift for `agent_status` and `agent_config_get` | `parity_check` + `gate-c` |
| Transaction surface expansion (core DEX offer ops) | grow agent action surface with validated constructors | unit tests |

## P1 (Next)
| Item | Outcome | Evidence |
|---|---|---|
| Live RPC method parity subset (`server_info`, `ledger`, `fee`, `submit`, `account_info`) | stable machine contracts with fixture+live checks | gate-c + gate-d |
| Control-plane policy enforcement | deny unsafe config transitions in production profile | tests + policy doc + gate-c |
| Agent runbook and capability matrix | explicit allowed actions by environment/profile | docs + CI artifact |

## P2
| Item | Outcome | Evidence |
|---|---|---|
| Deterministic multi-node scenario library | richer simulation for agent training/evaluation | sim artifacts + trend summaries |
| Tx-type completion wave (top usage set) | higher-fidelity autonomous workflow coverage | unit/integration tests |
| Ledger sync hardening | stronger replay/reconciliation behavior | integration tests + gate-d |

## P3
| Item | Outcome | Evidence |
|---|---|---|
| WASM tooling path (hooks-oriented) | compile-time + CI path for wasm experiments | dedicated wasm job + fixtures |
| Signed release artifact chain | supply-chain hardening for agent-delivered changes | provenance + signature verification in CI |
| Formal-invariant scaffolding | machine-checkable safety invariants over critical state transitions | invariant tests + gate reports |

## Tranche 1 (Implemented in this change)
- Hardened `src/rpc.zig` POST path:
  - path allowlist for JSON-RPC
  - `Content-Length` parsing and incomplete-body rejection
  - payload size cap for JSON body
  - JSON-RPC method-name validation
  - typed parsing for `agent_config_set` numeric/bool params
- Expanded transaction layer in `src/transaction.zig`:
  - `OfferCreateTransaction` + validation
  - `OfferCancelTransaction` + validation
- Added gate-linked control-plane evidence:
  - new fixture `test_data/agent_config_schema.json`
  - parity assertion in `src/parity_check.zig`
  - gate contract checks in `scripts/gates/gate_c.sh`
  - fixture manifest pin updated
