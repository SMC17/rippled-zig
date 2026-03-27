const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const transaction = @import("transaction.zig");

/// Example: Generate signing hash, sign with Ed25519, verify signature
///
/// This demonstrates the toolkit's end-to-end signing pipeline:
///   1. Construct a transaction and serialize it canonically
///   2. Generate an Ed25519 key pair
///   3. Sign the canonical bytes
///   4. Verify the signature against the public key
///
/// XRPL supports two signature algorithms:
///   - Ed25519: Modern, fast, constant-time. Used here.
///   - secp256k1 (ECDSA): Bitcoin-style. Requires libsecp256k1.
///
/// The signing flow is:
///   canonical_bytes -> SHA-512-Half(STX || canonical_bytes) -> sign(hash, privkey)
///   For Ed25519, the entire canonical payload is signed directly.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("rippled-zig Toolkit: Sign and Verify\n", .{});
    std.debug.print("=====================================\n\n", .{});

    // ---------------------------------------------------------------
    // 1. Generate an Ed25519 key pair
    // ---------------------------------------------------------------
    //
    // Ed25519 keys are 32-byte public + 64-byte secret (seed + public).
    // XRPL Ed25519 keys use a 0xED prefix on-chain, but the raw crypto
    // operations work on the bare 32-byte key.

    std.debug.print("1. Generating Ed25519 key pair...\n", .{});
    var key_pair = try crypto.KeyPair.generateEd25519(allocator);
    defer key_pair.deinit();

    std.debug.print("   Algorithm:  Ed25519\n", .{});
    std.debug.print("   Public key: {s}\n", .{std.fmt.fmtSliceHexLower(key_pair.public_key)});
    std.debug.print("   (Private key omitted for safety)\n\n", .{});

    // ---------------------------------------------------------------
    // 2. Derive the account ID from the public key
    // ---------------------------------------------------------------
    //
    // AccountID = RIPEMD-160(SHA-256(public_key))
    // This is the same derivation as Bitcoin addresses, producing
    // a 20-byte identifier that gets Base58Check-encoded for display.

    const account_id = key_pair.getAccountID();
    std.debug.print("2. Account ID (RIPEMD160(SHA256(pubkey))):\n", .{});
    std.debug.print("   {s}\n\n", .{std.fmt.fmtSliceHexLower(&account_id)});

    // ---------------------------------------------------------------
    // 3. Build and serialize a Payment transaction
    // ---------------------------------------------------------------

    const receiver: types.AccountID = [_]u8{0xBB} ** 20;
    var signing_pub_key: [33]u8 = undefined;
    // For Ed25519 on XRPL, the signing key is 0xED + 32-byte public key
    signing_pub_key[0] = 0xED;
    @memcpy(signing_pub_key[1..33], key_pair.public_key[0..32]);

    const payment = transaction.PaymentTransaction.create(
        account_id,
        receiver,
        types.Amount.fromXRP(25 * types.XRP), // 25 XRP
        types.MIN_TX_FEE, // 10 drops
        1, // sequence
        signing_pub_key,
    );

    const canonical_bytes = try payment.serialize(allocator);
    defer allocator.free(canonical_bytes);

    std.debug.print("3. Canonical transaction ({d} bytes):\n", .{canonical_bytes.len});
    std.debug.print("   {s}\n\n", .{std.fmt.fmtSliceHexLower(canonical_bytes)});

    // ---------------------------------------------------------------
    // 4. Sign the canonical bytes
    // ---------------------------------------------------------------
    //
    // For Ed25519, we sign the raw canonical bytes (the Ed25519 spec
    // already includes internal hashing). The result is a 64-byte
    // signature.

    std.debug.print("4. Signing transaction...\n", .{});
    const signature = try key_pair.sign(canonical_bytes, allocator);
    defer allocator.free(signature);

    std.debug.print("   Signature ({d} bytes):\n", .{signature.len});
    std.debug.print("   {s}\n\n", .{std.fmt.fmtSliceHexLower(signature)});

    // ---------------------------------------------------------------
    // 5. Verify the signature
    // ---------------------------------------------------------------
    //
    // Anyone with the public key can verify that this signature was
    // produced by the corresponding private key over these exact bytes.

    std.debug.print("5. Verifying signature...\n", .{});
    const valid = try crypto.KeyPair.verify(
        key_pair.public_key,
        canonical_bytes,
        signature,
        .ed25519,
    );

    if (valid) {
        std.debug.print("   [PASS] Signature is VALID\n\n", .{});
    } else {
        std.debug.print("   [FAIL] Signature is INVALID\n\n", .{});
        return;
    }

    // ---------------------------------------------------------------
    // 6. Demonstrate that tampering breaks the signature
    // ---------------------------------------------------------------
    //
    // Flip one bit in the canonical bytes and re-verify. The signature
    // must reject the modified data.

    std.debug.print("6. Tampering test (flip one byte, re-verify)...\n", .{});
    var tampered = try allocator.dupe(u8, canonical_bytes);
    defer allocator.free(tampered);
    tampered[0] ^= 0x01; // flip a bit

    const tampered_valid = try crypto.KeyPair.verify(
        key_pair.public_key,
        tampered,
        signature,
        .ed25519,
    );

    if (!tampered_valid) {
        std.debug.print("   [PASS] Tampered data correctly REJECTED\n\n", .{});
    } else {
        std.debug.print("   [FAIL] Tampered data was accepted!\n\n", .{});
    }

    // ---------------------------------------------------------------
    // 7. Demonstrate wrong-key rejection
    // ---------------------------------------------------------------

    std.debug.print("7. Wrong-key test (verify with different key)...\n", .{});
    var other_key = try crypto.KeyPair.generateEd25519(allocator);
    defer other_key.deinit();

    const wrong_key_valid = try crypto.KeyPair.verify(
        other_key.public_key,
        canonical_bytes,
        signature,
        .ed25519,
    );

    if (!wrong_key_valid) {
        std.debug.print("   [PASS] Wrong key correctly REJECTED\n\n", .{});
    } else {
        std.debug.print("   [FAIL] Wrong key was accepted!\n\n", .{});
    }

    std.debug.print("Summary:\n", .{});
    std.debug.print("  - Ed25519 sign/verify works end-to-end\n", .{});
    std.debug.print("  - Tampered data is rejected\n", .{});
    std.debug.print("  - Wrong-key signatures are rejected\n", .{});
    std.debug.print("  - secp256k1 signing requires libsecp256k1 (see build.zig)\n", .{});
}
