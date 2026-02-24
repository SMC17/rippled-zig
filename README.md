# rippled-zig

XRP Ledger protocol implementation in Zig for education and research.

**Status**: Alpha - Educational implementation based on XRPL specification  
**NOT for production use with real value**

---

## Overview

rippled-zig is an implementation of the XRP Ledger protocol in Zig, created for learning, research, and experimentation. It implements XRPL features based on the protocol specification, with a focus on memory safety and code clarity.

**Purpose**: Educational platform for understanding XRPL and learning Zig systems programming.

**NOT**: A production replacement for the official rippled (https://github.com/XRPLF/rippled)

## Source Of Truth

- **Canonical status**: `PROJECT_STATUS.md` (release decision, gates, evidence)
- **Architecture and backlog**: `docs/status/ARCHITECTURE_SOT.md`, `docs/status/AGENT_NATIVE_BACKLOG.md`
- **Control plane**: `docs/CONTROL_PLANE_POLICY.md`
- **Full index**: `docs/SOURCE_OF_TRUTH.md`
- **CI/gates**: `.github/workflows/quality-gates.yml`, `scripts/gates/`
- **Execution board**: `docs/GITHUB_EXECUTION_TRACK.md`, `docs/GITHUB_PROJECTS_SETUP.md`

All maturity/parity claims are considered untrusted unless backed by reproducible gate evidence in `PROJECT_STATUS.md`.

## What's Implemented

Current `main` includes:

- Core ledger/consensus/transaction modules with unit coverage
- Live JSON-RPC handling for:
  - `server_info`
  - `ledger`
  - `fee`
  - `ledger_current`
  - `account_info`
  - `submit` (minimal deserialize/validate/apply path)
  - `ping`
  - `agent_status`
  - `agent_config_get`
  - `agent_config_set`
- Control-plane profiles (`research` / `production`) with policy enforcement
- Gate-backed parity and conformance checks (A-E + simulation)

## Current Limitations

**NOT Validated Against**:
- Real XRPL mainnet or testnet
- rippled's actual behavior
- Real network transaction formats
- Production security requirements

**Known Gaps**:
- Full XRPL transaction and binary codec compatibility
- Complete P2P wire compatibility and robust ledger sync
- Exhaustive secp256k1 parity and production-grade crypto assurance
- Long-horizon soak, chaos, and security audit evidence

**Validation Status**: Unit tested, needs comprehensive real-network validation

## Installation

**Requirements**: Zig 0.15.1+

```bash
git clone https://github.com/SMC17/rippled-zig.git
cd rippled-zig
./zig build
./zig build test
```

If `./zig` is unavailable in your workspace:

```bash
zig build
zig build test
```

Run node with cache env auto-wired:

```bash
scripts/run.sh
```

## Use Cases

**Appropriate For**:
- Learning XRP Ledger protocol
- Understanding Byzantine consensus
- Studying Zig systems programming
- Educational projects
- Research and experimentation
- XRPL protocol documentation

**NOT Appropriate For**:
- Production validators
- Managing real XRP or assets
- Critical infrastructure
- Mainnet operations
- Any use requiring production reliability

## Architecture

Clean, educational codebase:
- `src/consensus.zig` - Byzantine consensus algorithm
- `src/transaction.zig` - Transaction validation
- `src/crypto.zig` - Cryptographic operations
- `src/ledger.zig` - Ledger state management
- See ARCHITECTURE.md for details

## Comparison with rippled

**Advantages**:
- Memory safe (Zig compile-time guarantees)
- Fast builds (<1 second vs 5-10 minutes)
- Clean code (15k lines vs 200k+)
- Educational value (easier to understand)

**Disadvantages**:
- Not battle-tested (rippled has 10+ years)
- Not validated against real network
- Missing production hardening
- Smaller community

**Recommendation**: Use rippled for production, rippled-zig for learning

## Contributing

Contributions welcome to help validate and improve!

**Priority**:
- Validation against real testnet data
- Comparison with rippled behavior
- Security review
- Test coverage expansion

See CONTRIBUTING.md

## Quality Gates

Primary verification flows:

```bash
scripts/gates/gate_a.sh artifacts/gate-a-local
scripts/gates/gate_b.sh artifacts/gate-b-local
scripts/gates/gate_c.sh artifacts/gate-c-local
scripts/gates/gate_e.sh artifacts/gate-e-local
```

Live testnet conformance (Gate D):

```bash
export TESTNET_RPC_URL="https://s.altnet.rippletest.net:51234/"
export TESTNET_WS_URL="wss://s.altnet.rippletest.net:51233/"
scripts/gates/gate_d.sh artifacts/gate-d-live
```

Operator setup/cadence/troubleshooting: `docs/GATE_D_OPERATOR_RUNBOOK.md`

## Security Warning

**IMPORTANT**: This is experimental software.

- NOT security audited
- NOT validated against production network
- MAY have bugs or vulnerabilities
- DO NOT use with real value without extensive validation

For production use, see official rippled: https://github.com/XRPLF/rippled

## Long-term Goal

Work toward verified compatibility with rippled through:
- Systematic validation against real network
- Byte-level comparison with rippled
- Security auditing
- Community testing

**Timeline**: Months to years of validation before production readiness

## License

ISC License - Same as rippled

## Resources

- Official rippled: https://github.com/XRPLF/rippled
- XRPL Documentation: https://xrpl.org/docs
- Zig Language: https://ziglang.org/

---

**An educational implementation of XRPL in Zig. Learn the protocol, understand the code, contribute to validation.**

**Use rippled for production. Use rippled-zig for learning.**
