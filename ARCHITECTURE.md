# rippled-zig Architecture

> Note: For current module maturity, ownership, and risk, see `docs/status/ARCHITECTURE_SOT.md`.

**Purpose**: Technical architecture overview for contributors

---

## System Overview

rippled-zig is organized into clear layers with minimal coupling and maximum cohesion.

```
┌─────────────────────────────────────────┐
│         Application Layer                │
│  (main.zig - Node coordinator)          │
└────────────┬────────────────────────────┘
             │
    ┌────────┴────────┐
    │                 │
    ▼                 ▼
┌─────────┐      ┌──────────┐
│   RPC   │      │ Network  │
│  Layer  │      │  Layer   │
└────┬────┘      └────┬─────┘
     │                │
     └────────┬───────┘
              ▼
       ┌──────────────┐
       │  Consensus   │
       │   Engine     │
       └──────┬───────┘
              │
              ▼
       ┌──────────────┐
       │ Transaction  │
       │  Processor   │
       └──────┬───────┘
              │
              ▼
       ┌──────────────┐
       │    Ledger    │
       │   Manager    │
       └──────┬───────┘
              │
              ▼
       ┌──────────────┐
       │   Storage    │
       │    Layer     │
       └──────────────┘
```

---

## Module Organization

### Core Modules (Foundation)

**types.zig**: XRPL type definitions
- No dependencies
- Pure data structures
- All other modules import this

**crypto.zig**: Cryptographic operations
- Depends on: types, ripemd160
- Provides: Hashing, signing, verification

**ledger.zig**: Ledger state management
- Depends on: types, crypto, merkle
- Manages: Ledger chain, account state

### Consensus Layer

**consensus.zig**: Byzantine Fault Tolerant consensus
- Depends on: types, ledger
- Implements: Multi-phase voting, validator coordination

**validators.zig**: Validator management
- Depends on: types, consensus
- Manages: UNL, validator tracking

### Transaction Layer

**transaction.zig**: Base transaction processing
- Depends on: types, ledger, crypto
- Provides: Validation framework

**Transaction Type Modules**:
- multisig.zig - Multi-signature transactions
- dex.zig - Decentralized exchange
- escrow.zig - Time-locked payments
- payment_channels.zig - Payment channels
- checks.zig - Check transactions
- nft.zig - NFT support

### Protocol Layer

**serialization.zig**: XRPL binary format
- Depends on: types
- Provides: Binary encoding/decoding

**canonical.zig**: Canonical field ordering
- Depends on: types
- Provides: Sorted field serialization

**base58.zig**: Address encoding
- Depends on: types, crypto
- Provides: Base58Check encoding

**merkle.zig**: Merkle tree implementation
- Depends on: crypto
- Provides: State tree hashing

**ripemd160.zig**: RIPEMD-160 hash
- No dependencies
- Pure algorithm implementation

**secp256k1.zig**: ECDSA support
- Depends on: types
- Status: Partial implementation

### Network Layer

**network.zig**: TCP peer-to-peer
- Depends on: types
- Provides: Peer connections, messaging

**rpc.zig**: HTTP server
- Depends on: types, ledger
- Provides: JSON-RPC API

**rpc_methods.zig**: RPC implementations
- Depends on: types, ledger, transaction
- Provides: API methods

**websocket.zig**: WebSocket server
- Depends on: types, ledger
- Provides: Real-time subscriptions

### Infrastructure Layer

**database.zig**: Key-value store
- Depends on: types, ledger
- Provides: Persistence

**storage.zig**: Storage abstraction
- Depends on: types, ledger
- Provides: Caching, storage interface

**config.zig**: Configuration
- Minimal dependencies
- Provides: Settings management

**logging.zig**: Structured logging
- Minimal dependencies
- Provides: Log management

**metrics.zig**: Monitoring
- Depends on: types
- Provides: Prometheus metrics

**security.zig**: Security hardening
- Minimal dependencies
- Provides: Rate limiting, validation

**performance.zig**: Performance utilities
- Minimal dependencies
- Provides: Lock-free structures, pooling

**pathfinding.zig**: Payment paths
- Depends on: types
- Provides: Cross-currency path finding

---

## Dependency Rules

1. **No Circular Dependencies**: Enforced by Zig
2. **types.zig has no dependencies**: Foundation layer
3. **main.zig coordinates, doesn't implement**: Thin coordinator
4. **Clear layer boundaries**: Network → Consensus → Transaction → Ledger → Storage

---

## Data Flow

### Transaction Processing

```
1. RPC receives transaction
2. Transaction processor validates
3. Add to pending pool
4. Consensus includes in proposal
5. Agreement reached (80% threshold)
6. Apply to ledger state
7. Store to database
8. Broadcast to subscribers
```

### Consensus Round

```
1. Open: Collect candidate transactions (2-3 seconds)
2. Establish: Create initial proposal
3. Rounds: Vote with increasing thresholds
   - 50% threshold
   - 60% threshold
   - 70% threshold
   - 80% threshold (final)
4. Validation: Apply agreed transaction set
5. Close: New ledger created
```

### State Management

```
1. Account states stored in database
2. State tree (merkle) calculates account_hash
3. Ledger header includes account_hash
4. Ledger hash calculated from header
5. Validated ledger added to history
```

---

## Testing Strategy

### Unit Tests

- Every public function tested
- Integrated in source files
- Run with `zig build test`

### Integration Tests

- End-to-end workflows
- Multi-component interaction
- In tests/integration.zig

### Validation Tests

- Against real XRPL testnet
- Verify compatibility
- In tests/*_validation.zig

---

## Performance Considerations

### Hot Paths

- Transaction validation
- Signature verification
- Hash calculations
- Serialization

### Optimizations Applied

- Lock-free queues for concurrency
- Memory pools for allocations
- Arena allocators for short-lived data
- Zero-copy where possible

---

## Security Model

### Memory Safety

- Compile-time bounds checking
- No null pointer dereferences
- No use-after-free
- Automatic resource cleanup

### Input Validation

- All external input validated
- Rate limiting on network interfaces
- Resource quotas enforced
- Sanitization applied

### Cryptographic Security

- RIPEMD-160 verified against test vectors
- Ed25519 using Zig std library
- SHA-512 Half per XRPL spec
- Secure random number generation

---

## Contributing to Architecture

When adding features:
1. Follow existing module patterns
2. Minimize dependencies
3. Add comprehensive tests
4. Document design decisions
5. Maintain layer boundaries

For major architectural changes:
1. Open discussion issue
2. Propose design
3. Get feedback
4. Implement with tests
5. Update this document

---

**This architecture supports the goal of full rippled parity while maintaining code clarity and safety.**
