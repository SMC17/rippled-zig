# Agent Runbook v2

**Purpose**: Closed-loop automation for AI agents interacting with rippled-zig. Use for training, evaluation, and autonomous experimentation.

## Prerequisites

- Zig 0.15.1+
- Node started with `profile=research` for write operations

## Quick Reference

| Step | Command | Purpose |
|------|---------|---------|
| Build | `./zig build` | Compile node |
| Test | `./zig build test` | Unit/integration tests |
| WASM | `./zig build wasm` | Protocol kernel + Hooks WASM |
| Gate A | `scripts/gates/gate_a.sh artifacts/gate-a-local` | Build + tests |
| Gate C | `scripts/gates/gate_c.sh artifacts/gate-c-local` | Parity + contracts |
| Sim | `scripts/sim/run_local_cluster.sh artifacts/sim-local` | Deterministic cluster |
| Run node | `scripts/run.sh` | Start daemon |

## Closed-Loop Flow (Agent v2)

1. **Read telemetry**: `agent_status` → `agent_control`, `node_state`
2. **Read config**: `agent_config_get` → current profile and parameters
3. **Adjust (research only)**: `agent_config_set` with allowlisted keys
4. **Run gates**: Execute Gate A, C, Sim; parse `artifacts/` for results
5. **Interpret**: Gate exit code 0 = pass; non-zero = fail
6. **Consume trends**: `crypto-trend-summary-7d.json`, `sim-trend-summary-7d.json`, etc.

### Interpreting Artifacts

| Artifact | Use |
|----------|-----|
| `gate-c-local/crypto-trend-summary-7d.json` | `success_rate`, `avg_positive_vectors`, `consecutive_strict_passes_from_latest` |
| `sim-local/simulation-summary.json` | `deterministic`, `metrics.success_rate`, `metrics.latest_ledger_seq` |
| `sim-local/round-events.ndjson` | Per-round events for agent training/evaluation |
| `sim-local/round-summary.ndjson` | Per-round leader, latency, success flags |
| `consensus-matrix/matrix-summary.json` | Deterministic consensus experiment matrix outputs + baseline deltas |

### Scenario Library

- **Base**: `scripts/sim/run_local_cluster.sh` — deterministic multi-node, configurable via `SIM_NODES`, `SIM_ROUNDS`, `SIM_SEED`
- **Agent scenarios**: `scripts/sim/run_agent_scenarios.sh artifacts/sim-agent` — runs standard (5 nodes, 20 rounds), training (7 nodes, 50 rounds), stress (high jitter) and produces `scenarios-summary.json`
- **Manifest-driven batch**: `scripts/sim/run_manifest_scenarios.sh artifacts/sim-manifest test_data/sim_scenarios_manifest.json` — runs manifest-declared scenarios (currently `standard`, `queue_pressure`) and produces `manifest-scenarios-summary.json`
- **Consensus experiment matrix**: `scripts/sim/run_consensus_experiment_matrix.sh artifacts/consensus-matrix test_data/consensus_experiment_matrix_manifest.json` — runs manifest-declared consensus parameter sweeps (3+ experiments) and produces deterministic `matrix-summary.json`

## JSON-RPC Examples

```json
{"method":"agent_status"}
{"method":"agent_config_get"}
{"method":"agent_config_set","params":{"key":"fee_multiplier","value":2}}
```

## Artifact Locations

- Gate A: `artifacts/gate-a-local/`
- Gate C: `artifacts/gate-c-local/` (or `artifacts/gate-c/`)
- Simulation: `artifacts/sim-local/` — `simulation-summary.json`, `round-events.ndjson`, `round-summary.ndjson`
- Research experiments: `artifacts/consensus-matrix/` — per-experiment summaries + `matrix-summary.json`

## Policy Boundary

- **Production profile**: Only read methods allowed; `submit` and `agent_config_set` return `"Method blocked by profile policy"`.
- **Research profile**: All methods allowed; use for experimentation and mutation.
