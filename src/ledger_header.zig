const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");

/// XRPL Ledger Header — the fixed-size header for each closed ledger.
///
/// The hash of a ledger header uniquely identifies the ledger and
/// forms a hash chain (each header references its parent).
///
/// Fields (per XRPL spec, serialized in this order for hashing):
///   - Sequence (u32)
///   - TotalCoins (u64) — total XRP drops in existence
///   - ParentHash (32 bytes) — hash of previous ledger header
///   - TransactionHash (32 bytes) — SHAMap root of transaction tree
///   - AccountStateHash (32 bytes) — SHAMap root of state tree
///   - ParentCloseTime (u32) — Ripple epoch time of parent close
///   - CloseTime (u32) — Ripple epoch time of this ledger close
///   - CloseTimeResolution (u8) — rounding for close time
///   - CloseFlags (u8) — 0x01 = close time is exact

pub const LEDGER_HASH_PREFIX = [_]u8{ 0x4C, 0x57, 0x52, 0x00 }; // "LWR\0"

pub const LedgerHeader = struct {
    sequence: u32,
    total_coins: u64,
    parent_hash: [32]u8,
    transaction_hash: [32]u8, // SHAMap root of tx tree
    account_state_hash: [32]u8, // SHAMap root of state tree
    parent_close_time: u32, // Ripple epoch seconds
    close_time: u32, // Ripple epoch seconds
    close_time_resolution: u8, // seconds (typically 10)
    close_flags: u8, // 0x01 = exact close time

    /// Compute the hash of this ledger header.
    /// hash = SHA-512-Half(LWR_PREFIX || serialized_header)
    pub fn computeHash(self: LedgerHeader) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha512.init(.{});
        hasher.update(&LEDGER_HASH_PREFIX);

        // Serialize fields in canonical order
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.sequence, .big);
        hasher.update(&buf);

        var buf8: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf8, self.total_coins, .big);
        hasher.update(&buf8);

        hasher.update(&self.parent_hash);
        hasher.update(&self.transaction_hash);
        hasher.update(&self.account_state_hash);

        std.mem.writeInt(u32, &buf, self.parent_close_time, .big);
        hasher.update(&buf);

        std.mem.writeInt(u32, &buf, self.close_time, .big);
        hasher.update(&buf);

        hasher.update(&[_]u8{self.close_time_resolution});
        hasher.update(&[_]u8{self.close_flags});

        var full: [64]u8 = undefined;
        hasher.final(&full);
        var result: [32]u8 = undefined;
        @memcpy(&result, full[0..32]);
        return result;
    }

    /// Verify the hash chain: this ledger's parent_hash must match parent's computed hash.
    pub fn verifyParent(self: LedgerHeader, parent: LedgerHeader) !void {
        const parent_computed = parent.computeHash();
        if (!std.mem.eql(u8, &self.parent_hash, &parent_computed)) {
            return error.ParentHashMismatch;
        }
        if (self.sequence != parent.sequence + 1) {
            return error.SequenceGap;
        }
        if (self.parent_close_time != parent.close_time) {
            return error.ParentCloseTimeMismatch;
        }
    }

    /// Validate internal consistency of the header.
    pub fn validate(self: LedgerHeader) !void {
        if (self.sequence == 0) return error.InvalidSequence;
        if (self.total_coins > types.MAX_XRP) return error.TotalCoinsExceedsMax;
        if (self.close_time_resolution == 0) return error.InvalidCloseTimeResolution;
        if (self.close_time < self.parent_close_time and self.sequence > 1) {
            return error.CloseTimeBeforeParent;
        }
    }

    /// Create the genesis ledger header.
    pub fn genesis() LedgerHeader {
        return .{
            .sequence = 1,
            .total_coins = types.MAX_XRP,
            .parent_hash = [_]u8{0} ** 32,
            .transaction_hash = [_]u8{0} ** 32,
            .account_state_hash = [_]u8{0} ** 32,
            .parent_close_time = 0,
            .close_time = 0,
            .close_time_resolution = 10,
            .close_flags = 0,
        };
    }
};

/// Verify a chain of ledger headers (from oldest to newest).
pub fn verifyChain(headers: []const LedgerHeader) !void {
    if (headers.len < 2) return;
    for (1..headers.len) |i| {
        try headers[i].verifyParent(headers[i - 1]);
    }
}

// ── Tests ──

test "genesis ledger header" {
    const genesis = LedgerHeader.genesis();
    try genesis.validate();
    try std.testing.expectEqual(@as(u32, 1), genesis.sequence);
    try std.testing.expectEqual(types.MAX_XRP, genesis.total_coins);
}

test "ledger hash is deterministic" {
    const h1 = LedgerHeader.genesis().computeHash();
    const h2 = LedgerHeader.genesis().computeHash();
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "different headers produce different hashes" {
    var h1 = LedgerHeader.genesis();
    var h2 = LedgerHeader.genesis();
    h2.sequence = 2;
    try std.testing.expect(!std.mem.eql(u8, &h1.computeHash(), &h2.computeHash()));
}

test "parent hash chain verification" {
    const parent = LedgerHeader.genesis();
    var child = LedgerHeader{
        .sequence = 2,
        .total_coins = types.MAX_XRP,
        .parent_hash = parent.computeHash(),
        .transaction_hash = [_]u8{0} ** 32,
        .account_state_hash = [_]u8{0} ** 32,
        .parent_close_time = 0,
        .close_time = 10,
        .close_time_resolution = 10,
        .close_flags = 0,
    };
    try child.verifyParent(parent);
}

test "parent hash chain rejects mismatch" {
    const parent = LedgerHeader.genesis();
    var child = LedgerHeader{
        .sequence = 2,
        .total_coins = types.MAX_XRP,
        .parent_hash = [_]u8{0xFF} ** 32, // wrong!
        .transaction_hash = [_]u8{0} ** 32,
        .account_state_hash = [_]u8{0} ** 32,
        .parent_close_time = 0,
        .close_time = 10,
        .close_time_resolution = 10,
        .close_flags = 0,
    };
    try std.testing.expectError(error.ParentHashMismatch, child.verifyParent(parent));
}

test "validate rejects invalid header" {
    var h = LedgerHeader.genesis();
    h.total_coins = types.MAX_XRP + 1;
    try std.testing.expectError(error.TotalCoinsExceedsMax, h.validate());
}

test "chain verification" {
    const genesis = LedgerHeader.genesis();
    const ledger2 = LedgerHeader{
        .sequence = 2,
        .total_coins = types.MAX_XRP,
        .parent_hash = genesis.computeHash(),
        .transaction_hash = [_]u8{0} ** 32,
        .account_state_hash = [_]u8{0} ** 32,
        .parent_close_time = 0,
        .close_time = 10,
        .close_time_resolution = 10,
        .close_flags = 0,
    };
    const ledger3 = LedgerHeader{
        .sequence = 3,
        .total_coins = types.MAX_XRP,
        .parent_hash = ledger2.computeHash(),
        .transaction_hash = [_]u8{0} ** 32,
        .account_state_hash = [_]u8{0} ** 32,
        .parent_close_time = 10,
        .close_time = 20,
        .close_time_resolution = 10,
        .close_flags = 0,
    };
    const chain = [_]LedgerHeader{ genesis, ledger2, ledger3 };
    try verifyChain(&chain);
}
