# Agent Capability Matrix

**Purpose**: Explicit allowed actions by environment and profile for AI/automation clients.

Canonical policy: [`docs/CONTROL_PLANE_POLICY.md`](CONTROL_PLANE_POLICY.md)

## Method Allowlist by Profile

| Method | Research | Production | Notes |
|--------|----------|------------|-------|
| `server_info` | Yes | Yes | Read-only |
| `ledger` | Yes | Yes | Read-only |
| `ledger_current` | Yes | Yes | Read-only |
| `fee` | Yes | Yes | Read-only |
| `ping` | Yes | Yes | Read-only |
| `account_info` | Yes | Yes | Read-only |
| `agent_status` | Yes | Yes | Telemetry for control loops |
| `agent_config_get` | Yes | Yes | Read config |
| `agent_config_set` | Yes | **No** | Blocked in production |
| `submit` | Yes | **No** | Blocked in production |

## `agent_config_set` Keys (Research Only)

| Key | Type | Range/Constraints |
|-----|------|-------------------|
| `profile` | string | `"research"` or `"production"` (with invariant checks) |
| `max_peers` | integer | 1–1000 |
| `fee_multiplier` | integer | 1–10 |
| `strict_crypto_required` | boolean | - |
| `allow_unl_updates` | boolean | - |

## Production Profile Invariants

To transition to `production`, all must hold:
- `strict_crypto_required == true`
- `allow_unl_updates == false`
- `fee_multiplier <= 5`
- `max_peers <= 100`

## Closed-Loop Test Automation

1. Start node with `profile=research`.
2. Call `agent_status` to verify `mode == "research"`.
3. Run Gate A: `scripts/gates/gate_a.sh artifacts/gate-a-local`.
4. Run Gate C: `scripts/gates/gate_c.sh artifacts/gate-c-local`.
5. Parse artifacts for pass/fail; fail fast on any gate failure.
6. Optional: transition to `production` via `agent_config_set` with valid invariants, then verify `submit` returns policy error.
