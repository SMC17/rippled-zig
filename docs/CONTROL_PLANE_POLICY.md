# Control Plane Policy

Status: Active policy reference for agent control methods.

Scope:
- `agent_status`
- `agent_config_get`
- `agent_config_set`
- RPC method boundary behavior by profile

Primary implementation references:
- `src/rpc_methods.zig`
- `src/rpc.zig`
- `scripts/gates/gate_c.sh`
- `test_data/agent_status_schema.json`
- `test_data/agent_config_schema.json`
- `test_data/rpc_live_negative_schema.json`

## Profiles

### `research`
Purpose: enable controlled experimentation and iterative development.

Behavior:
- RPC methods are broadly allowed.
- `agent_config_set` is available with allowlisted keys and value validation.

### `production`
Purpose: enforce a hard operational boundary.

Behavior:
- Only explicit allowlist methods are accepted.
- Methods outside allowlist return deterministic policy error.
- Runtime config mutation via `agent_config_set` is blocked by method boundary.

## Production Method Allowlist
Allowed methods:
- `server_info`
- `ledger`
- `ledger_current`
- `fee`
- `ping`
- `agent_status`
- `agent_config_get`
- `account_info`

Denied methods include:
- `submit`
- `agent_config_set`
- any other non-allowlisted method

Deterministic error:
- `"Method blocked by profile policy"`

## `agent_config_set` Allowlisted Keys
- `profile`
- `max_peers`
- `fee_multiplier`
- `strict_crypto_required`
- `allow_unl_updates`

Validation behavior:
- unsupported key -> `"Unsupported config key"`
- parse/type failure -> `"Invalid config value"`
- range failure -> `"Config value out of range"`
- malformed params payload -> `"Invalid agent_config_set params"`

## Unsafe Transition Rules
Transitioning into `production` is denied unless invariants are satisfied.

Required invariants for `production` profile:
- `strict_crypto_required == true`
- `allow_unl_updates == false`
- `fee_multiplier <= 5`
- `max_peers <= 100`

Deterministic errors:
- entering production with invalid invariants -> `"Unsafe profile transition"`
- violating policy while already in production path -> `"Policy violation for current profile"`

## Contract Enforcement
Gate-backed enforcement paths:
- Unit tests:
  - `src/rpc_methods.zig` profile and invariant tests
  - `src/rpc.zig` JSON-RPC profile boundary tests
- Gate C fixtures/contracts:
  - `test_data/agent_status_schema.json`
  - `test_data/agent_config_schema.json`
  - `test_data/rpc_live_negative_schema.json` (`submit_blocked_in_production`)
  - `scripts/gates/gate_c.sh`

## Operational Guidance
1. Use `research` for all autonomous experimentation and mutation.
2. Treat `production` as read-dominant and policy-constrained.
3. Require code review and signed artifacts for any policy-surface change.
4. Do not enable unreviewed self-modifying control loops on production profile.
