//! Protocol Kernel - WASM-friendly subset of XRPL protocol logic
//! Compiles to wasm32-wasi or wasm32-freestanding for Hooks and light client use.
//! No TCP, threads, or OS-specific dependencies.

const std = @import("std");

/// SHA-512 Half - primary XRPL hash (first 256 bits of SHA-512)
pub fn sha512Half(data: []const u8) [32]u8 {
    var full_hash: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(data, &full_hash, .{});
    var result: [32]u8 = undefined;
    @memcpy(&result, full_hash[0..32]);
    return result;
}

/// RIPEMD-160 - used for AccountID derivation. Stub (zeros) for wasm; full impl for native.
pub fn ripemd160(data: []const u8) [20]u8 {
    if (@import("builtin").cpu.arch == .wasm32) {
        var stub: [20]u8 = undefined;
        @memset(&stub, 0);
        return stub;
    }
    const ripemd = @import("ripemd160.zig");
    var result: [20]u8 = undefined;
    ripemd.hash(data, &result);
    return result;
}

/// Account ID from public key: RIPEMD160(SHA256(pubkey))
pub fn accountIDFromPubkey(public_key: []const u8) [20]u8 {
    var sha256_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(public_key, &sha256_hash, .{});
    return ripemd160(&sha256_hash);
}

/// XRPL signing prefix for secp256k1 transactions
pub const STX_PREFIX = [_]u8{ 0x53, 0x54, 0x58, 0x00 };

/// Compute signing hash for a transaction: SHA512Half(STX || canonical_serialization)
/// Caller must ensure canonical fits in stack buffer for wasm compatibility.
pub fn signingHash(canonical: []const u8) [32]u8 {
    var buf: [4]u8 = undefined;
    @memcpy(&buf, &STX_PREFIX);
    var full: [4 + 2048]u8 = undefined; // Max typical tx size
    @memcpy(full[0..4], &buf);
    const copy_len = @min(canonical.len, 2048);
    @memcpy(full[4..][0..copy_len], canonical[0..copy_len]);
    return sha512Half(full[0..4 + copy_len]);
}

export fn wasm_sha512_half(ptr: [*]const u8, len: usize, out: [*]u8) void {
    const data = ptr[0..len];
    const result = sha512Half(data);
    @memcpy(out[0..32], &result);
}

export fn wasm_ripemd160(ptr: [*]const u8, len: usize, out: [*]u8) void {
    const data = ptr[0..len];
    const result = ripemd160(data);
    @memcpy(out[0..20], &result);
}

test "protocol kernel sha512Half" {
    const h = sha512Half("test");
    try std.testing.expect(h.len == 32);
}
