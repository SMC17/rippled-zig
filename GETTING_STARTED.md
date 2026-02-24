# Getting Started with rippled-zig

This guide will help you get started with the Zig-based XRP Ledger daemon implementation.

## Prerequisites

- Zig 0.15.1 or later
- Basic understanding of the XRP Ledger
- Familiarity with Zig (optional but helpful)

## Building the Project

### 1. Clone or navigate to the project directory

```bash
cd /Users/seancollins/rippled-zig
```

### 2. Build the project

```bash
./zig build
```

### 3. Run tests

```bash
./zig build test
```

### 4. Run the daemon

```bash
scripts/run.sh
```

## Project Structure Overview

```
rippled-zig/
├── src/
│   ├── main.zig          - Entry point and node coordination
│   ├── types.zig         - Core XRP Ledger types (Account, Amount, Currency)
│   ├── crypto.zig        - Cryptographic operations (Ed25519, hashing)
│   ├── ledger.zig        - Ledger management and state
│   ├── consensus.zig     - XRP Ledger Consensus Protocol
│   ├── transaction.zig   - Transaction processing and validation
│   ├── network.zig       - P2P networking (partial)
│   ├── rpc.zig           - JSON-RPC server + live method dispatch
│   └── storage.zig       - Ledger storage and caching
├── build.zig            - Build configuration
├── scripts/run.sh       - Standard local run entrypoint
├── scripts/gates/       - Quality/parity/conformance/security gates
├── README.md            - Main documentation
└── LICENSE              - ISC License

```

## Quick Examples

### Creating a Payment Transaction

```zig
const payment = PaymentTransaction.create(
    sender_account_id,
    receiver_account_id,
    Amount.fromXRP(100 * types.XRP),  // 100 XRP
    types.MIN_TX_FEE,                  // 10 drops
    1,                                  // sequence number
    signing_pub_key,
);
```

### Working with Amounts

```zig
// Create XRP amount
const xrp_amount = types.Amount.fromXRP(1000 * types.XRP);  // 1000 XRP

// Check if amount is XRP
if (amount.isXRP()) {
    // Handle XRP
}
```

### Generating Keys

```zig
const allocator = std.heap.page_allocator;
var key_pair = try crypto.KeyPair.generateEd25519(allocator);
defer key_pair.deinit();

// Get account ID
const account_id = key_pair.getAccountID();
```

## Development Workflow

### 1. Make Changes

Edit the source files in the `src/` directory.

### 2. Run Tests

```bash
./zig build test
```

### 3. Build and Run

```bash
scripts/run.sh
```

### 4. Check for Issues

If you encounter build errors related to Zig version compatibility, ensure you're using Zig 0.15.1 or later:

```bash
zig version
```

### 5. If using an AI coding agent

Read these first so your automation behavior matches the project's current safety boundaries:
- `PROJECT_STATUS.md`
- `docs/CONTROL_PLANE_POLICY.md`
- `docs/AGENT_AUTOMATION_POLICY.md`

## Current Limitations

This is an early-stage implementation with the following limitations:

- [ ] P2P/network sync paths are incomplete for full compatibility
- [ ] `submit` supports a minimal blob path, not full XRPL serialization
- [ ] Storage is simplified (no RocksDB/NuDB integration)
- [ ] Consensus rounds are simplified vs production behavior
- [ ] No mainnet-ready hardening or security audit evidence

## Next Steps for Development

1. Implement full P2P protocol
2. Add RPC/WebSocket server with all API methods
3. Integrate proper database backend (consider RocksDB bindings)
4. Implement complete consensus rounds with validator communication
5. Add transaction validation for all transaction types
6. Implement ledger history fetching and replay
7. Add configuration file support
8. Add logging system
9. Performance optimization
10. Security audits

## Learning Resources

- **XRP Ledger Docs**: https://xrpl.org/docs
- **Original rippled**: https://github.com/XRPLF/rippled
- **Zig Documentation**: https://ziglang.org/documentation/master/
- **Consensus Paper**: https://arxiv.org/abs/1802.07242

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## Getting Help

- Read the main README.md
- Read `PROJECT_STATUS.md` for canonical maturity/gate status
- Check the source code documentation
- Review the original rippled documentation
- Open an issue on GitHub

## License

ISC License - same as the original rippled project.
