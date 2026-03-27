# rippled-zig

An XRPL Protocol Toolkit in Zig -- canonical transaction encoding, signing-hash generation, signature verification, and live RPC conformance for a declared subset of the XRP Ledger protocol.

[![Gate A](https://img.shields.io/badge/Gate_A-Build_%2B_Test-brightgreen)](#quality-gates)
[![Gate B](https://img.shields.io/badge/Gate_B-Deterministic_Serialization-brightgreen)](#quality-gates)
[![Gate C](https://img.shields.io/badge/Gate_C-Cross--Impl_Parity-brightgreen)](#quality-gates)
[![Gate D](https://img.shields.io/badge/Gate_D-Live_Testnet-brightgreen)](#quality-gates)
[![Gate E](https://img.shields.io/badge/Gate_E-Security_%2B_Fuzz-brightgreen)](#quality-gates)
[![Zig](https://img.shields.io/badge/Zig-0.14.1-orange)](https://ziglang.org/)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)

---

## What This Is

rippled-zig is a compact, auditable Zig implementation of core XRPL protocol surfaces: binary transaction encoding, cryptographic signing and verification, and a selected set of JSON-RPC methods tested against live testnet endpoints.

It is a **toolkit and library**, not a node. It does not participate in consensus, sync ledgers, or operate as a validator.

For production node operation, use the official [rippled](https://github.com/XRPLF/rippled).

## What It Does

| Capability | Scope | Status |
|---|---|---|
| **Canonical transaction encoding** | Payment, AccountSet, OfferCreate, OfferCancel | Gate B verified |
| **Signing-hash generation** | SHA-512Half with XRPL `STX` prefix domain separation | Gate B/C verified |
| **Signature verification** | secp256k1 (via libsecp256k1) + Ed25519 (via Zig std) | Gate C strict crypto |
| **Live RPC conformance** | `server_info`, `fee`, `ledger`, `ledger_current`, `account_info`, `submit` | Gate D verified |
| **Base58Check encoding** | XRPL address encode/decode with RIPEMD-160 | Unit tested |
| **Deterministic serialization** | Canonical field ordering per XRPL binary format spec | Gate B fixture manifest |
| **CLI surface** | Build, test, run, gate execution | Stable |

## What It Does Not Do

- Validator or full node operation
- P2P overlay / peer protocol
- Ledger sync or history
- Consensus participation
- Persistent storage

These are explicitly outside the v1 release claim. See [PROJECT_STATUS.md](PROJECT_STATUS.md) for the exact boundary.

---

## Installation

**Requirements**
- Zig 0.14.1
- `libsecp256k1` for strict ECDSA verification paths
- C compiler (Zig ships one, or use system `cc`)

```bash
git clone https://github.com/SMC17/rippled-zig.git
cd rippled-zig
```

**Build and test**

```bash
zig build
zig build test
```

**Run the toolkit CLI**

```bash
zig build run -- help
zig build run -- version
zig build run -- encode-tx rAddr1 rAddr2 1000000 12 1
zig build run -- hash-tx <hex_bytes>
zig build run -- verify-sig <hash_hex> <sig_hex> <pubkey_hex>
zig build run -- encode-address <hex_account_id>
```

**Run quality gates locally**

```bash
scripts/gates/gate_a.sh artifacts/gate-a-local
scripts/gates/gate_b.sh artifacts/gate-b-local
scripts/gates/gate_c.sh artifacts/gate-c-local
scripts/gates/gate_e.sh artifacts/gate-e-local
```

**Run live testnet conformance (Gate D)**

```bash
export TESTNET_RPC_URL="https://s.altnet.rippletest.net:51234/"
export TESTNET_WS_URL="wss://s.altnet.rippletest.net:51233/"
scripts/gates/gate_d.sh artifacts/gate-d-live
```

---

## Quick Start

**Encode a canonical Payment transaction**

```bash
# Via CLI
zig build run -- encode-tx rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh 1000000 12 1

# Or build with -Dexperimental=true for full node modules
zig build -Dexperimental=true
```

The toolkit's primary surfaces are importable Zig modules:

```
src/canonical_tx.zig   -- canonical XRPL field ordering and binary encoding
src/transaction.zig    -- transaction modeling and serialization
src/crypto.zig         -- signing-hash generation and key utilities
src/secp256k1.zig      -- ECDSA signature verification
src/base58.zig         -- Base58Check address encoding
src/rpc.zig            -- JSON-RPC server with selected method handlers
src/rpc_methods.zig    -- RPC method implementations
```

---

## Architecture

```
                  +-----------------------+
                  |     CLI / Library     |
                  |      (main.zig)       |
                  +----------+------------+
                             |
              +--------------+--------------+
              |                             |
    +---------v----------+       +----------v---------+
    |   Codec Layer      |       |    RPC Layer       |
    |                    |       |                    |
    | canonical_tx.zig   |       | rpc.zig            |
    | transaction.zig    |       | rpc_methods.zig    |
    | serialization.zig  |       +--------------------+
    +--------+-----------+
             |
    +--------v-----------+
    |   Crypto Layer     |
    |                    |
    | crypto.zig         |
    | secp256k1.zig      |
    | secp256k1_binding  |
    | ripemd160.zig      |
    | base58.zig         |
    +--------------------+
```

**Codec Layer** -- Canonical binary encoding of XRPL transactions. Field ordering follows the XRPL serialization specification. Variable-length encoding handles all VL boundary classes (192/193, 12480/12481).

**Crypto Layer** -- SHA-512Half signing-hash generation with `STX` prefix domain separation. secp256k1 ECDSA verification via system libsecp256k1. Ed25519 via Zig standard library. RIPEMD-160 for AccountID derivation. Base58Check for address encoding.

**RPC Layer** -- HTTP JSON-RPC server handling `server_info`, `fee`, `ledger`, `ledger_current`, `account_info`, and `submit` for the declared transaction subset.

The repository also contains experimental modules (consensus, peer protocol, ledger sync, storage) that are **not** part of the v1 release surface. They remain for research purposes and carry no correctness claims.

---

## Quality Gates

Every commit to `main` must pass Gates A through E. Gate D accepts an explicit skip artifact when testnet secrets are unavailable.

| Gate | What It Proves | Script | Artifacts |
|---|---|---|---|
| **A** | Build + unit/integration tests pass on required OS matrix | `gate_a.sh` | Build log, test results |
| **B** | Deterministic serialization and hash vectors reproduce | `gate_b.sh` | Fixture SHA-256 manifest, vector hashes |
| **C** | Cross-implementation parity with rippled fixtures; strict secp256k1 verification | `gate_c.sh` | Parity results, signing-domain checks |
| **D** | Live testnet conformance for declared RPC subset | `gate_d.sh` | Endpoint health, trend summaries |
| **E** | Security scans, fuzz budget enforcement, crash-free markers | `gate_e.sh` | Security metrics, fuzz artifacts |
| **Sim** | Deterministic local multi-node simulation | `gate_sim.sh` | Simulation summary, round events |

Gate results, trend summaries, and ops digests are published as CI artifacts on every run. See [PROJECT_STATUS.md](PROJECT_STATUS.md) for the evidence register.

---

## Supported RPC Methods

| Method | Mode | Gate Coverage |
|---|---|---|
| `server_info` | Live + fixture | D, C |
| `fee` | Live + fixture | D, C |
| `ledger` | Live + fixture | D, C |
| `ledger_current` | Live + fixture | D, C |
| `account_info` | Live + fixture | D, C |
| `submit` | Narrow transaction subset | D, C |

All methods return deterministic error contracts for malformed or unsupported input.

---

## Supported Transaction Types (v1)

| Type | Canonical Encoding | Signing Hash | Verification |
|---|---|---|---|
| Payment | Yes | Yes | Yes |
| AccountSet | Yes | Yes | Yes |
| OfferCreate | Yes | Yes | Yes |
| OfferCancel | Yes | Yes | Yes |

---

## Project Status

- **Release candidate**: Not yet. Active development toward v1.
- **Target date**: 2026-07-31
- **Milestone**: `v1 XRPL Toolkit` ([Epic #45](https://github.com/SMC17/rippled-zig/issues/45))
- **Canonical status**: [PROJECT_STATUS.md](PROJECT_STATUS.md)

All maturity claims are considered untrusted unless backed by reproducible gate evidence.

---

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

**Current priorities** (in delivery order):

1. **Scope freeze** -- #46, #47, #61: Reposition docs, prune examples, lock toolchain
2. **Codec and crypto correctness** -- #48-#54: Complete canonical encoding and verification for declared transaction set
3. **Live conformance and release** -- #55-#62: RPC subset hardening, CLI surface, signed release artifacts

**To contribute**:

1. Fork the repository
2. Create a feature branch
3. Ensure all gates pass locally (`scripts/gates/gate_a.sh` through `gate_e.sh`)
4. Open a pull request against `main`

---

## Security

This is pre-release software. It has not been independently security audited.

- Do not use with real value without extensive independent validation
- Do not deploy as infrastructure
- Report security issues via GitHub Security Advisories

For production XRPL operations, use [rippled](https://github.com/XRPLF/rippled).

---

## Source of Truth

| Document | Purpose |
|---|---|
| [PROJECT_STATUS.md](PROJECT_STATUS.md) | Release decision, gate evidence, risk register |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Technical architecture for contributors |
| [docs/SOURCE_OF_TRUTH.md](docs/SOURCE_OF_TRUTH.md) | Full document index |
| [docs/GATE_D_OPERATOR_RUNBOOK.md](docs/GATE_D_OPERATOR_RUNBOOK.md) | Live testnet gate operations |

If any other document conflicts with PROJECT_STATUS.md, PROJECT_STATUS.md is authoritative.

---

## License

ISC License -- same as rippled. See [LICENSE](LICENSE).

## Resources

- Official rippled: https://github.com/XRPLF/rippled
- XRPL Documentation: https://xrpl.org/docs
- Zig Language: https://ziglang.org/
