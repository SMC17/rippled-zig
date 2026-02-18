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

- Canonical status and release decision: `PROJECT_STATUS.md`
- CI quality gates: `.github/workflows/quality-gates.yml`
- Gate scripts: `scripts/gates/`

All maturity/parity claims are considered untrusted unless backed by reproducible gate evidence in `PROJECT_STATUS.md`.

## What's Implemented

Based on XRPL specification:

- 25 transaction type structures (Payment, DEX, Escrow, Channels, Checks, NFTs, etc.)
- 30 RPC method skeletons
- Byzantine Fault Tolerant consensus logic
- Cryptographic primitives (RIPEMD-160, Ed25519, SHA-512)
- Serialization framework
- Network protocol structures
- Database and infrastructure

**Total**: 14,988 lines of Zig code with 80+ tests

## Current Limitations

**NOT Validated Against**:
- Real XRPL mainnet or testnet
- rippled's actual behavior
- Real network transaction formats
- Production security requirements

**Known Gaps**:
- secp256k1 signature verification (partial)
- Exact serialization format matching
- Network protocol compatibility
- Real-world edge cases

**Validation Status**: Unit tested, needs comprehensive real-network validation

## Installation

**Requirements**: Zig 0.15.1+

```bash
git clone https://github.com/SMC17/rippled-zig.git
cd rippled-zig
zig build
zig build test
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
