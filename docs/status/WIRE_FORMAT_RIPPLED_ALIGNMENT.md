# Wire Format Alignment with rippled

**Status:** Design doc for future rippled peer protocol compatibility.

## Current State

rippled-zig uses a **custom binary wire format** for peer protocol:

- **Framing:** 4-byte big-endian length prefix, then payload
- **Hello:** `[protocol_version:4][network_id:4][node_id:32][ledger_seq:4][ledger_hash:32][app_name_len:1][app_name]`
- **Message types:** Ping(1), Pong(2), Transaction(3), GetLedger(4), LedgerData(5), Proposal(6), Validation(7)

This format is compatible with other rippled-zig nodes but **not** with rippled.

## rippled Protocol

rippled uses:

1. **Transport:** HTTPS (TLS) to port 51235, then HTTP Upgrade to `XRPL/2.0`
2. **Message format:** Protocol Buffers–based peer messages (see [rippled overlay](https://github.com/XRPLF/rippled/tree/master/src/xrpld/overlay))
3. **Message framing:** Different from our length-prefixed binary (protobuf-encoded)

## Alignment Path

| Phase | Deliverable |
|-------|-------------|
| 1 (done) | TLS + HTTP Upgrade transport (see `overlay_https.zig`) |
| 2 | Protobuf schema for rippled peer messages |
| 3 | Wire encoder/decoder for rippled Hello, ping, GetLedger, LedgerData |
| 4 | Optional: dual-mode (custom for rippled-zig↔rippled-zig, protobuf for rippled) |

## References

- [XRPL Peer Protocol](https://xrpl.org/docs/concepts/networks-and-servers/peer-protocol)
- [rippled overlay source](https://github.com/XRPLF/rippled/tree/master/src/xrpld/overlay)
- [Binary format (transaction/ledger)](https://xrpl.org/docs/references/protocol/binary-format)
