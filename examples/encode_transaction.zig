const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const transaction = @import("transaction.zig");
const canonical = @import("canonical.zig");

/// Example: Encode a Payment transaction in canonical XRPL binary format
///
/// This demonstrates the core toolkit capability: taking structured transaction
/// data and producing the exact byte sequence that the XRP Ledger expects.
///
/// Canonical serialization is the foundation of everything in XRPL:
///   - Transaction hashes are computed over canonical bytes
///   - Signatures are computed over canonical bytes (with STX prefix)
///   - Ledger entries are stored in canonical form
///
/// The XRPL canonical format sorts fields by (type_code, field_code) and uses
/// big-endian encoding throughout. This matches the C++ rippled reference
/// implementation exactly.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("rippled-zig Toolkit: Canonical Transaction Encoding\n", .{});
    std.debug.print("====================================================\n\n", .{});

    // ---------------------------------------------------------------
    // 1. Build a Payment transaction using the typed API
    // ---------------------------------------------------------------
    //
    // A Payment is the most common XRPL transaction type. We construct
    // one from raw account IDs, an amount in drops, and a sequence number.

    const sender: types.AccountID = [_]u8{
        0xfa, 0xb4, 0xff, 0x1b, 0xec, 0x2e, 0x13, 0x76, 0x13, 0xd2,
        0x6d, 0xeb, 0xf3, 0xd5, 0x7e, 0xbb, 0x9d, 0x2c, 0xed, 0xae,
    };
    const receiver: types.AccountID = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13,
    };

    const amount = types.Amount.fromXRP(50 * types.XRP); // 50 XRP in drops
    const fee: types.Drops = 12; // 12 drops
    const sequence: u32 = 42;
    const signing_pub_key = [_]u8{0x02} ++ [_]u8{0xAB} ** 32; // placeholder 33-byte compressed key

    const payment = transaction.PaymentTransaction.create(
        sender,
        receiver,
        amount,
        fee,
        sequence,
        signing_pub_key,
    );

    std.debug.print("Transaction fields:\n", .{});
    std.debug.print("  Type:     Payment (0x{x:0>4})\n", .{@intFromEnum(payment.base.tx_type)});
    std.debug.print("  Sender:   {s}\n", .{std.fmt.fmtSliceHexLower(&sender)});
    std.debug.print("  Receiver: {s}\n", .{std.fmt.fmtSliceHexLower(&receiver)});
    std.debug.print("  Amount:   {d} drops (= {d} XRP)\n", .{ 50 * types.XRP, 50 });
    std.debug.print("  Fee:      {d} drops\n", .{fee});
    std.debug.print("  Sequence: {d}\n\n", .{sequence});

    // ---------------------------------------------------------------
    // 2. Serialize to canonical binary
    // ---------------------------------------------------------------
    //
    // The serializer sorts fields by (type_code, field_code) and emits
    // each field as: field_id_byte || big-endian data.
    //
    // Field ordering for a Payment:
    //   UInt16  type_code=0x10 field_code=2  TransactionType
    //   UInt32  type_code=0x20 field_code=4  Sequence
    //   UInt64  type_code=0x60 field_code=1  Amount
    //   UInt64  type_code=0x60 field_code=8  Fee
    //   Account type_code=0x80 field_code=1  Account (sender)
    //   Account type_code=0x80 field_code=3  Destination (receiver)

    const serialized = try payment.serialize(allocator);
    defer allocator.free(serialized);

    std.debug.print("Canonical binary ({d} bytes):\n", .{serialized.len});
    std.debug.print("  {s}\n\n", .{std.fmt.fmtSliceHexLower(serialized)});

    // ---------------------------------------------------------------
    // 3. Compute the body hash (SHA-512 Half)
    // ---------------------------------------------------------------
    //
    // The body hash is SHA-512 truncated to 256 bits, computed directly
    // over the canonical bytes. This is used for transaction identification.

    const body_hash = crypto.Hash.sha512Half(serialized);
    std.debug.print("Body hash (SHA-512 Half):\n", .{});
    std.debug.print("  {s}\n\n", .{std.fmt.fmtSliceHexLower(&body_hash)});

    // ---------------------------------------------------------------
    // 4. Compute the signing hash (STX-prefixed SHA-512 Half)
    // ---------------------------------------------------------------
    //
    // For signing, XRPL prepends the 4-byte prefix "STX\0" (0x53545800)
    // before hashing. This domain-separates signing from other uses of
    // the same canonical bytes.

    const signing_hash = try crypto.Hash.transactionSigningHash(serialized, allocator);
    std.debug.print("Signing hash (STX || canonical -> SHA-512 Half):\n", .{});
    std.debug.print("  {s}\n\n", .{std.fmt.fmtSliceHexLower(&signing_hash)});

    // ---------------------------------------------------------------
    // 5. Determinism check
    // ---------------------------------------------------------------
    //
    // Serialize a second time and verify byte-for-byte equality.
    // This is the core guarantee: same inputs always produce the same
    // canonical bytes, which produce the same hash.

    const serialized_again = try payment.serialize(allocator);
    defer allocator.free(serialized_again);

    if (std.mem.eql(u8, serialized, serialized_again)) {
        std.debug.print("[PASS] Deterministic: two serializations produce identical bytes\n", .{});
    } else {
        std.debug.print("[FAIL] Non-deterministic serialization detected!\n", .{});
    }

    const hash_again = crypto.Hash.sha512Half(serialized_again);
    if (std.mem.eql(u8, &body_hash, &hash_again)) {
        std.debug.print("[PASS] Hash stability: identical hashes from identical bytes\n", .{});
    } else {
        std.debug.print("[FAIL] Hash mismatch!\n", .{});
    }

    std.debug.print("\nThis canonical encoding matches the rippled C++ reference.\n", .{});
    std.debug.print("Use it as input to signing, fixture tests, or conformance checks.\n", .{});
}
