# Gate D Operator Runbook

Status: operational runbook for live testnet conformance (`scripts/gates/gate_d.sh`).

## Purpose
Run Gate D consistently and produce decision-grade artifacts for live XRPL testnet conformance checks.

Gate D validates:
- endpoint reachability (`https` RPC + `wss` WebSocket URL shape)
- live `server_info`, `fee`, `ledger` responses
- negative contracts (`account_info`, `submit`)
- method-level latency thresholds
- trend-point output for rolling summaries

## Required Environment
- `TESTNET_RPC_URL` (must be `https://...`)
- `TESTNET_WS_URL` (must be `wss://...`)
- tools: `curl`, `jq`, `awk`

Optional:
- `GATE_D_PROFILE` (`default`)
- `GATE_D_MAX_LATENCY_S`
- `GATE_D_MIN_LEDGER_SEQ`
- `GATE_D_EXPECTED_NETWORK_ID`
- `GATE_D_TREND_INPUT_DIR` (for rolling trend merge)

## How To Get Testnet URLs
Use one of these sources:
1. XRPL testnet public endpoints (example defaults often used in docs):
   - RPC: `https://s.altnet.rippletest.net:51234/`
   - WS: `wss://s.altnet.rippletest.net:51233/`
2. A managed provider endpoint pair (recommended for reliability):
   - ensure both URLs point to the same testnet provider/environment
   - verify RPC is HTTPS and WS is WSS

Selection rules:
- Prefer stable provider endpoints for recurring trend runs.
- Keep RPC/WS paired from the same provider to avoid drift.
- Do not use mainnet endpoints for Gate D testnet conformance.

## Local Run (Manual)
```bash
export TESTNET_RPC_URL="https://s.altnet.rippletest.net:51234/"
export TESTNET_WS_URL="wss://s.altnet.rippletest.net:51233/"

scripts/gates/gate_d.sh artifacts/gate-d-live
```

Artifacts produced (key files):
- `testnet-conformance.json`
- `trend-point.json`
- method payloads/metrics (`server_info.*`, `fee.*`, `ledger.*`, `ping.*`, `ledger_current.*`)
- negative payloads/metrics (`account_info_negative.*`, `submit_negative.*`)

## CI / Scheduled Run Cadence
Recommended cadence:
1. `PR / push`: allow `SKIPPED` artifact when secrets are unavailable.
2. Daily scheduled run: execute with real testnet secrets and persist artifacts.
3. Weekly review: inspect 7-day trend summary for latency drift and failure reasons.

Minimum operating discipline:
- Keep at least 7 days of `trend-point.json` and `testnet-conformance.json`.
- Investigate any consecutive failures before changing thresholds.
- Treat threshold changes as reviewed policy updates, not ad hoc fixes.

## Secrets Handling and Rotation
Storage:
- local shell/session env vars for manual runs
- GitHub Actions secrets for scheduled/CI runs

Rotation procedure:
1. Update `TESTNET_RPC_URL` and `TESTNET_WS_URL` together (paired provider endpoints).
2. Run one manual Gate D check and confirm `status=pass` or explicit `skipped`.
3. For CI, update secrets and trigger a run.
4. Compare `trend-point.json` latency to prior baseline before changing thresholds.

When to rotate:
- provider deprecation / endpoint sunset
- repeated DNS/TLS errors
- persistent latency regressions caused by endpoint quality

## Troubleshooting Checklist
### Missing Secrets
- Symptom: `TESTNET_RPC_URL and TESTNET_WS_URL are required`
- Action:
  - set both env vars
  - or run with `GATE_D_ALLOW_SKIP_NO_SECRETS=true` for local non-live validation

### Scheme Errors
- Symptom: URL scheme failure (`https://` / `wss://`)
- Action: correct scheme; Gate D intentionally rejects insecure/non-matching schemes

### HTTP / Curl Failure
- Symptom: `HTTP failure for payload`
- Action:
  - check endpoint reachability
  - verify provider is testnet, not mainnet
  - retry outside VPN/proxy if applicable

### Latency Threshold Breach
- Symptom: `Latency threshold exceeded`
- Action:
  - inspect `*.metrics` files in artifact dir
  - compare with recent `trend-summary-7d.json`
  - retry once before treating as persistent regression

### Contract Drift / Unexpected Response Shape
- Symptom: missing field, non-numeric field, or status mismatch
- Action:
  - inspect raw method payload artifact (`*.json`)
  - confirm endpoint/provider and network (`network_id`)
  - if upstream changed behavior, update Gate D only after documenting contract change and reconciling Gate C/Gate D expectations

### Cross-Endpoint Mismatch (`server_info` vs `ledger`)
- Symptom: seq/hash mismatch
- Action:
  - rerun once (possible race between validated/current ledger windows)
  - if persistent, capture artifacts and open an issue with provider + timestamp

## Evidence Checklist (Before Claiming “Gate D Green”)
- `testnet-conformance.json` has `status: pass`
- `trend-point.json` exists
- method payloads present for `server_info`, `fee`, `ledger`, `ping`, `ledger_current`
- negative payloads present for `account_info` and `submit`
- thresholds and observed values are captured in artifact JSON

## Contributor Handoff (No Verbal Handoff Required)
Use this sequence:
1. Export `TESTNET_RPC_URL` and `TESTNET_WS_URL`
2. Run `scripts/gates/gate_d.sh artifacts/gate-d-<date>`
3. Read `artifacts/gate-d-<date>/testnet-conformance.json`
4. If failing, follow troubleshooting checklist above
5. If passing, archive artifacts and (optionally) run trend merge with `GATE_D_TREND_INPUT_DIR`
