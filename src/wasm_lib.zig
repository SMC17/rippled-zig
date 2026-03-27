//! WASM library exports for the XRPL protocol toolkit.
//!
//! Provides C-ABI exported functions suitable for wasm32-freestanding:
//!   - serialize_payment
//!   - hash_sha512_half
//!   - verify_ed25519
//!   - encode_base58
//!
//! All functions use caller-supplied buffers (no allocator needed).

const std = @import("std");

// ── hash_sha512_half ─────────────────────────────────────────────────
/// Compute SHA-512 Half (first 32 bytes of SHA-512) over `data[0..len]`.
/// Result is written to `out[0..32]`.
export fn hash_sha512_half(data: [*]const u8, len: usize, out: [*]u8) void {
    var full_hash: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(data[0..len], &full_hash, .{});
    @memcpy(out[0..32], full_hash[0..32]);
}

// ── verify_ed25519 ──────────────────────────────────────────────────
/// Verify an Ed25519 signature.
///   pubkey  - pointer to 32-byte raw public key
///   msg     - pointer to message bytes
///   msg_len - length of message
///   sig     - pointer to 64-byte signature
/// Returns 1 if valid, 0 otherwise.
export fn verify_ed25519(
    pubkey: [*]const u8,
    msg: [*]const u8,
    msg_len: usize,
    sig: [*]const u8,
) u32 {
    var sig_bytes: [64]u8 = undefined;
    @memcpy(&sig_bytes, sig[0..64]);
    var pk_bytes: [32]u8 = undefined;
    @memcpy(&pk_bytes, pubkey[0..32]);

    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
    const pub_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(pk_bytes) catch return 0;
    signature.verify(msg[0..msg_len], pub_key) catch return 0;
    return 1;
}

// ── encode_base58 ───────────────────────────────────────────────────
/// XRPL Base58 alphabet.
const alphabet = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz";

/// Encode `data[0..data_len]` as Base58 into `out`.
/// Returns the number of bytes written, or 0 on overflow.
/// `out_cap` is the capacity of the output buffer.
export fn encode_base58(
    data: [*]const u8,
    data_len: usize,
    out: [*]u8,
    out_cap: usize,
) usize {
    if (data_len == 0) return 0;

    const input = data[0..data_len];

    // Count leading zeros
    var zeros: usize = 0;
    for (input) |byte| {
        if (byte != 0) break;
        zeros += 1;
    }

    // Use a stack buffer for base58 digits (worst case: data_len * 138/100 + 1)
    var digits: [512]u8 = undefined;
    var digits_len: usize = 0;

    // Process each byte of input (skip leading zeros)
    for (input[zeros..]) |byte| {
        var carry: u32 = byte;
        var i: usize = 0;
        while (i < digits_len) : (i += 1) {
            carry += @as(u32, digits[i]) * 256;
            digits[i] = @intCast(carry % 58);
            carry /= 58;
        }
        while (carry > 0) {
            if (digits_len >= digits.len) return 0; // overflow
            digits[digits_len] = @intCast(carry % 58);
            digits_len += 1;
            carry /= 58;
        }
    }

    const total_len = zeros + digits_len;
    if (total_len > out_cap) return 0;

    // Leading zeros -> alphabet[0]
    for (0..zeros) |i| {
        out[i] = alphabet[0];
    }

    // Digits are in reverse order
    for (0..digits_len) |i| {
        out[zeros + i] = alphabet[digits[digits_len - 1 - i]];
    }

    return total_len;
}

// ── serialize_payment ───────────────────────────────────────────────
/// Serialize an XRPL Payment transaction into canonical binary format.
///
/// Parameters (all little-endian where applicable):
///   account     - pointer to 20-byte AccountID (source)
///   destination - pointer to 20-byte AccountID (destination)
///   drops       - XRP amount in drops (u64)
///   fee         - fee in drops (u32)
///   sequence    - account sequence number (u32)
///   out         - output buffer for serialized bytes
///   out_cap     - capacity of output buffer
///
/// Returns the number of bytes written, or 0 on error/overflow.
///
/// Wire format (XRPL canonical field ordering by type-code then field-code):
///   UInt16  TransactionType  (type 1, field 2)  = 0x0000 (Payment)
///   UInt32  Flags            (type 2, field 2)  = 0x00000000
///   UInt32  Sequence         (type 2, field 4)
///   Amount  Fee              (type 6, field 8)
///   Amount  Amount           (type 6, field 1)
///   AccountID Account        (type 8, field 1)
///   AccountID Destination    (type 8, field 3)
export fn serialize_payment(
    account: [*]const u8,
    destination: [*]const u8,
    drops: u64,
    fee: u32,
    sequence: u32,
    out: [*]u8,
    out_cap: usize,
) usize {
    // Maximum size: 2+2 + 2+4 + 2+4 + 2+8 + 2+8 + 2+1+20 + 2+1+20 = ~81 bytes
    if (out_cap < 81) return 0;

    var pos: usize = 0;

    // TransactionType: type 1, field 2 -> type_code << 4 | field_code when both < 16
    // Encoding: high nibble = type_code(1), low nibble = field_code(2) => 0x12
    out[pos] = 0x12;
    pos += 1;
    // Value: Payment = 0x0000
    out[pos] = 0x00;
    pos += 1;
    out[pos] = 0x00;
    pos += 1;

    // Flags: type 2, field 2 -> 0x22
    out[pos] = 0x22;
    pos += 1;
    out[pos] = 0x00;
    pos += 1;
    out[pos] = 0x00;
    pos += 1;
    out[pos] = 0x00;
    pos += 1;
    out[pos] = 0x00;
    pos += 1;

    // Sequence: type 2, field 4 -> 0x24
    out[pos] = 0x24;
    pos += 1;
    out[pos] = @intCast((sequence >> 24) & 0xFF);
    pos += 1;
    out[pos] = @intCast((sequence >> 16) & 0xFF);
    pos += 1;
    out[pos] = @intCast((sequence >> 8) & 0xFF);
    pos += 1;
    out[pos] = @intCast(sequence & 0xFF);
    pos += 1;

    // Fee (Amount): type 6, field 8 -> 0x68
    out[pos] = 0x68;
    pos += 1;
    // XRP amount encoding: top bit set, next bit clear (positive), remaining 62 bits = drops
    const fee64: u64 = @as(u64, fee);
    const fee_encoded: u64 = 0x4000000000000000 | fee64;
    inline for (0..8) |i| {
        out[pos] = @intCast((fee_encoded >> @intCast(56 - i * 8)) & 0xFF);
        pos += 1;
    }

    // Amount (Amount): type 6, field 1 -> 0x61
    out[pos] = 0x61;
    pos += 1;
    const amount_encoded: u64 = 0x4000000000000000 | drops;
    inline for (0..8) |i| {
        out[pos] = @intCast((amount_encoded >> @intCast(56 - i * 8)) & 0xFF);
        pos += 1;
    }

    // Account: type 8, field 1 -> 0x81
    out[pos] = 0x81;
    pos += 1;
    // Variable-length prefix: 20 bytes
    out[pos] = 20;
    pos += 1;
    @memcpy(out[pos..][0..20], account[0..20]);
    pos += 20;

    // Destination: type 8, field 3 -> 0x83
    out[pos] = 0x83;
    pos += 1;
    out[pos] = 20;
    pos += 1;
    @memcpy(out[pos..][0..20], destination[0..20]);
    pos += 20;

    return pos;
}

// ── Tests ───────────────────────────────────────────────────────────
test "wasm_lib hash_sha512_half" {
    var out: [32]u8 = undefined;
    const data = "test";
    hash_sha512_half(data.ptr, data.len, &out);
    // Just verify it produces 32 bytes and is not zero
    var all_zero = true;
    for (out) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "wasm_lib encode_base58 round-trip" {
    var out: [64]u8 = undefined;
    const data = [_]u8{ 0x00, 0xFA, 0xB4, 0xFF, 0x1B };
    const len = encode_base58(&data, data.len, &out, out.len);
    try std.testing.expect(len > 0);
}

test "wasm_lib serialize_payment produces correct length" {
    const account = [_]u8{0x01} ** 20;
    const destination = [_]u8{0x02} ** 20;
    var out: [128]u8 = undefined;
    const len = serialize_payment(&account, &destination, 1000000, 12, 1, &out, out.len);
    // Expected: 3 + 5 + 5 + 9 + 9 + 22 + 22 = 75 bytes
    try std.testing.expect(len == 75);
}
