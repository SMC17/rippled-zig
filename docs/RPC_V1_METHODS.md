# v1 Supported RPC Methods

The v1 release supports the following RPC methods with full positive and negative contract coverage.

## Supported Methods

| Method | Positive Contract | Negative Contract | Live (Gate D) |
|--------|:--:|:--:|:--:|
| `server_info` | PASS | PASS | PASS |
| `fee` | PASS | PASS | PASS |
| `ledger` | PASS | PASS | PASS |
| `ledger_current` | PASS | PASS | PASS |
| `account_info` | PASS | PASS | PASS |
| `submit` | PASS | PASS | Excluded |

## Submit Scope

The `submit` method accepts only the v1 supported transaction set:
- **Payment** (type 0)
- **AccountSet** (type 3)
- **OfferCreate** (type 7)
- **OfferCancel** (type 8)

Unsupported transaction types return a deterministic `notSupported` error.

## Profile Boundaries

- **Research profile**: All methods available
- **Production profile**: `submit` is blocked; only read-only methods allowed

## Contract Schema Files

- `test_data/rpc_live_methods_schema.json` — positive response contracts
- `test_data/rpc_live_negative_schema.json` — negative/error contracts
