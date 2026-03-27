# Getting Started with rippled-zig

This guide will help you get started with the toolkit-first v1 release path.

## Prerequisites

- Zig `0.14.1`
- `libsecp256k1` for strict verification paths
- Basic understanding of the XRP Ledger
- Familiarity with Zig (optional but helpful)

## Building the Project

### 1. Clone or navigate to the project directory

```bash
cd /Users/seancollins/rippled-zig
```

### 2. Confirm the toolchain

```bash
zig version
```

Expected output:

```bash
0.14.1
```

### 3. Build the project

```bash
zig build
```

### 4. Run tests

```bash
zig build test
```

### 5. Run the standard local entrypoint

```bash
scripts/run.sh
```

## Product Scope Overview

```
rippled-zig/
├── src/
│   ├── main.zig          - current local entrypoint
│   ├── transaction.zig   - transaction modeling and serialization entrypoints
│   ├── canonical_tx.zig  - canonical XRPL field ordering and encoding
│   ├── crypto.zig        - signing-hash generation and key utilities
│   ├── secp256k1*.zig    - signature verification paths
│   ├── rpc.zig           - JSON-RPC server + live method dispatch
│   └── rpc_methods.zig   - selected live RPC method handling
├── build.zig            - Build configuration
├── scripts/run.sh       - Standard local entrypoint
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

If you encounter build errors related to Zig version compatibility, ensure you're using Zig `0.14.1` exactly:

```bash
zig version
```

### 5. If using an AI coding agent

Read these first so your automation behavior matches the project's current safety boundaries:
- `PROJECT_STATUS.md`
- `docs/CONTROL_PLANE_POLICY.md`
- `docs/AGENT_AUTOMATION_POLICY.md`

## Current Limitations

The active v1 release path has the following limitations:

- [ ] Canonical XRPL codec work is incomplete for the full supported set
- [ ] `submit` remains intentionally narrow on the release path
- [ ] Strict verification depends on `libsecp256k1`
- [ ] Experimental runtime/peer modules remain out of v1 scope
- [ ] No mainnet-ready hardening or security audit evidence

## Next Steps for Development

1. Close `#46`, `#47`, and `#61` to finish the scope freeze and toolchain parity pass
2. Close `#48`-`#50` to make Gate B represent the real v1 codec surface
3. Close `#51`-`#54` to lock crypto and verification evidence
4. Close `#55`-`#57` to freeze and validate the live RPC subset
5. Close `#58`-`#60` to ship the public API, CLI, and examples
6. Close `#62` to complete the release checklist and signed artifact path

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
