#!/usr/bin/env bash

# Fetch real XRPL testnet data for validation
# This data will be used to verify our implementation matches reality

set -euo pipefail

mkdir -p test_data

echo "Fetching real XRPL testnet data..."

# Testnet RPC endpoint
TESTNET_RPC="${TESTNET_RPC:-https://s.altnet.rippletest.net:51234}"
TEST_ACCOUNT="${TEST_ACCOUNT:-rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T}"

# 1. Get current ledger
echo "Fetching current validated ledger..."
curl -sS -X POST "$TESTNET_RPC" \
  -H "Content-Type: application/json" \
  -d '{"method":"ledger","params":[{"ledger_index":"validated","transactions":true,"expand":true}]}' \
  | jq '.' > test_data/current_ledger.json

# 2. Get server info
echo "Fetching server info..."
curl -sS -X POST "$TESTNET_RPC" \
  -H "Content-Type: application/json" \
  -d '{"method":"server_info"}' \
  | jq '.' > test_data/server_info.json

# 3. Get fee info
echo "Fetching fee info..."
curl -sS -X POST "$TESTNET_RPC" \
  -H "Content-Type: application/json" \
  -d '{"method":"fee"}' \
  | jq '.' > test_data/fee_info.json

# 4. Get some account info
echo "Fetching test account..."
curl -sS -X POST "$TESTNET_RPC" \
  -H "Content-Type: application/json" \
  -d "{\"method\":\"account_info\",\"params\":[{\"account\":\"$TEST_ACCOUNT\",\"ledger_index\":\"validated\"}]}" \
  | jq '.' > test_data/account_info.json

# 5. Get recent transactions
echo "Fetching recent transactions..."
curl -sS -X POST "$TESTNET_RPC" \
  -H "Content-Type: application/json" \
  -d '{"method":"tx","params":[{"transaction":"latest","binary":false}]}' \
  | jq '.' > test_data/recent_tx.json 2>/dev/null || echo "No recent tx"

echo ""
echo "✅ Test data fetched successfully"
echo ""
echo "Files created in test_data/:"
ls -lh test_data/

echo ""
echo "Next: Use this data to validate our implementation"
echo "Run: zig build test-validation"
