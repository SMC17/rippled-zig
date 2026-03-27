const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const base58 = @import("base58.zig");

/// Example: Base58Check encode and decode XRPL addresses
///
/// XRPL addresses look like "rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T". Under the
/// hood they are Base58Check-encoded 20-byte account IDs.
///
/// The encoding is:
///   1. Prepend version byte 0x00 (identifies "account address")
///   2. Compute checksum: first 4 bytes of SHA-256(SHA-256(version + payload))
///   3. Append checksum
///   4. Base58-encode the 25-byte result using the XRPL alphabet
///
/// The XRPL alphabet is different from Bitcoin's:
///   rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz
///
/// This toolkit handles the full round-trip: pubkey -> accountID -> address -> accountID.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("rippled-zig Toolkit: Address Encoding\n", .{});
    std.debug.print("======================================\n\n", .{});

    // ---------------------------------------------------------------
    // 1. Start from a known public key (test vector)
    // ---------------------------------------------------------------
    //
    // This compressed secp256k1 public key is from the project's test
    // vectors. The expected XRPL address is "rPickFLAKK7YkMwKvhSEN1yJAtfnB6qRJc".

    const pub_key_hex = "02D3FC6F04117E6420CAEA735C57CEEC934820BBCD109200933F6BBDD98F7BFBD9";
    var pub_key: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&pub_key, pub_key_hex);

    std.debug.print("1. Public key (compressed secp256k1, 33 bytes):\n", .{});
    std.debug.print("   {s}\n\n", .{std.fmt.fmtSliceHexLower(&pub_key)});

    // ---------------------------------------------------------------
    // 2. Derive the 20-byte account ID
    // ---------------------------------------------------------------
    //
    // AccountID = RIPEMD-160(SHA-256(public_key))
    // This two-step hash compresses the 33-byte key down to 20 bytes.

    const account_id = crypto.Hash.accountID(&pub_key);

    std.debug.print("2. Account ID = RIPEMD-160(SHA-256(pubkey)):\n", .{});
    std.debug.print("   {s}\n\n", .{std.fmt.fmtSliceHexLower(&account_id)});

    // ---------------------------------------------------------------
    // 3. Encode as XRPL address (Base58Check)
    // ---------------------------------------------------------------
    //
    // The encoding process:
    //   [0x00] + [20-byte account_id] + [4-byte checksum]
    //   -> Base58 encode using XRPL alphabet
    //   -> Result starts with 'r' (from version byte 0x00)

    const address = try base58.Base58.encodeAccountID(allocator, account_id);
    defer allocator.free(address);

    std.debug.print("3. XRPL address (Base58Check):\n", .{});
    std.debug.print("   {s}\n\n", .{address});

    // Verify against known test vector
    const expected_address = "rPickFLAKK7YkMwKvhSEN1yJAtfnB6qRJc";
    if (std.mem.eql(u8, address, expected_address)) {
        std.debug.print("   [PASS] Matches known test vector: {s}\n\n", .{expected_address});
    } else {
        std.debug.print("   [FAIL] Expected {s}, got {s}\n\n", .{ expected_address, address });
    }

    // ---------------------------------------------------------------
    // 4. Decode the address back to account ID
    // ---------------------------------------------------------------
    //
    // Decoding verifies the checksum and strips the version byte,
    // returning the raw 20-byte account ID. A corrupted address will
    // be rejected with an InvalidChecksum error.

    const decoded_id = try base58.Base58.decodeAccountID(allocator, address);

    std.debug.print("4. Round-trip decode:\n", .{});
    std.debug.print("   Decoded account ID: {s}\n", .{std.fmt.fmtSliceHexLower(&decoded_id)});

    if (std.mem.eql(u8, &account_id, &decoded_id)) {
        std.debug.print("   [PASS] Round-trip: encode -> decode produces original account ID\n\n", .{});
    } else {
        std.debug.print("   [FAIL] Round-trip mismatch!\n\n", .{});
    }

    // ---------------------------------------------------------------
    // 5. Demonstrate checksum protection
    // ---------------------------------------------------------------
    //
    // If we corrupt a single character in the address, the checksum
    // will catch it. This protects users from sending funds to a
    // mistyped address.

    std.debug.print("5. Checksum protection:\n", .{});
    var corrupted: [expected_address.len]u8 = undefined;
    @memcpy(&corrupted, expected_address);
    // Flip one character (change 'P' to 'Q' in "rPick...")
    corrupted[1] = if (corrupted[1] == 'Q') 'R' else 'Q';

    const decode_result = base58.Base58.decodeAccountID(allocator, &corrupted);
    if (decode_result) |id| {
        // If it happens to decode (unlikely), check if it matches
        _ = id;
        std.debug.print("   Corrupted address decoded (checksum collision -- rare)\n\n", .{});
    } else |err| {
        std.debug.print("   Corrupted address \"{s}\" rejected: {s}\n", .{ corrupted, @errorName(err) });
        std.debug.print("   [PASS] Checksum correctly caught the corruption\n\n", .{});
    }

    // ---------------------------------------------------------------
    // 6. Generate a fresh address from an Ed25519 key
    // ---------------------------------------------------------------

    std.debug.print("6. Fresh Ed25519 key -> address:\n", .{});
    var key_pair = try crypto.KeyPair.generateEd25519(allocator);
    defer key_pair.deinit();

    const fresh_id = key_pair.getAccountID();
    const fresh_address = try base58.Base58.encodeAccountID(allocator, fresh_id);
    defer allocator.free(fresh_address);

    std.debug.print("   Public key:  {s}\n", .{std.fmt.fmtSliceHexLower(key_pair.public_key)});
    std.debug.print("   Account ID:  {s}\n", .{std.fmt.fmtSliceHexLower(&fresh_id)});
    std.debug.print("   Address:     {s}\n", .{fresh_address});
    std.debug.print("   Starts with 'r': {}\n\n", .{fresh_address[0] == 'r'});

    // ---------------------------------------------------------------
    // 7. Demonstrate raw Base58 encode/decode
    // ---------------------------------------------------------------
    //
    // The Base58 codec also works on arbitrary data. This is useful
    // for encoding seed values, validation public keys, etc.

    std.debug.print("7. Raw Base58 encode/decode:\n", .{});
    const raw_data = "Hello, XRPL!";
    const encoded = try base58.Base58.encode(allocator, raw_data);
    defer allocator.free(encoded);

    const decoded = try base58.Base58.decode(allocator, encoded);
    defer allocator.free(decoded);

    std.debug.print("   Input:   \"{s}\"\n", .{raw_data});
    std.debug.print("   Encoded: {s}\n", .{encoded});
    std.debug.print("   Decoded: \"{s}\"\n", .{decoded});

    if (std.mem.eql(u8, raw_data, decoded)) {
        std.debug.print("   [PASS] Raw Base58 round-trip OK\n\n", .{});
    } else {
        std.debug.print("   [FAIL] Raw Base58 round-trip mismatch\n\n", .{});
    }

    std.debug.print("Summary:\n", .{});
    std.debug.print("  - XRPL addresses are Base58Check over 20-byte account IDs\n", .{});
    std.debug.print("  - Account IDs come from RIPEMD-160(SHA-256(public_key))\n", .{});
    std.debug.print("  - Checksums protect against typos and corruption\n", .{});
    std.debug.print("  - The XRPL alphabet differs from Bitcoin's (starts with 'r')\n", .{});
}
