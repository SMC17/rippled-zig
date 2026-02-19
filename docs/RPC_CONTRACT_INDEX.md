# RPC Contract Index

Status: Contract index for currently live JSON-RPC methods.

This index maps each live method to fixture/schema contracts and gate evidence.

## Contract Matrix

| Method | Contract Type | Source Of Truth | Gate Evidence |
|---|---|---|---|
| `server_info` | live conformance assertions (status/info fields, network_id, validated ledger shape) | `scripts/gates/gate_d.sh` + live artifact `testnet-conformance.json` | Gate D |
| `ledger` | live cross-endpoint consistency (seq/hash with `server_info`) | `scripts/gates/gate_d.sh` + live artifact `ledger.json` | Gate D |
| `fee` | live fee/status contract and threshold checks | `scripts/gates/gate_d.sh` + live artifact `fee.json` | Gate D |
| `account_info` | strict schema contract for local live-path + negative-case contract | `test_data/rpc_live_methods_schema.json`, `test_data/rpc_live_negative_schema.json`, `src/parity_check.zig` | Gate C, Gate D negative contract |
| `submit` | strict schema contract for success payload + deterministic negative-case contracts | `test_data/rpc_live_methods_schema.json`, `test_data/rpc_live_negative_schema.json`, `src/parity_check.zig` | Gate C, Gate D negative contract |
| `ping` | strict minimal schema contract | `test_data/rpc_live_methods_schema.json`, `src/parity_check.zig` | Gate C |
| `ledger_current` | strict schema contract for required result fields | `test_data/rpc_live_methods_schema.json`, `src/parity_check.zig` | Gate C |
| `agent_status` | strict schema + expected-value contract | `test_data/agent_status_schema.json`, `src/parity_check.zig` | Gate C |
| `agent_config_get` | strict schema + expected-value contract | `test_data/agent_config_schema.json`, `src/parity_check.zig` | Gate C |
| `agent_config_set` | policy/error contract coverage through tests and profile boundary checks | `src/rpc.zig`, `src/rpc_methods.zig`, `test_data/rpc_live_negative_schema.json` (`submit_blocked_in_production`) | Gate A tests, Gate C policy case |

## Deterministic Negative Cases (Current)
From `test_data/rpc_live_negative_schema.json`:
- `account_info_missing_param`
- `account_info_invalid_account`
- `submit_missing_blob`
- `submit_empty_blob`
- `submit_non_hex_blob`
- `submit_invalid_blob_structure`
- `submit_missing_destination_account`
- `submit_insufficient_payment_balance`
- `submit_blocked_in_production`

## Contract Governance Rules
1. No live-method maturity claim without fixture/schema or explicit live gate assertions.
2. Contract changes must update fixture manifest and Gate C checks.
3. `PROJECT_STATUS.md` remains the canonical release-decision authority.
