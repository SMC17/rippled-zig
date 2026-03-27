const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");

/// Multi-Signature Support for XRPL
/// BLOCKER #4 FIX
/// Signer for multi-signature transaction
pub const Signer = struct {
    account: types.AccountID,
    signing_pub_key: [33]u8,
    txn_signature: []const u8,

    pub fn deinit(self: *Signer, allocator: std.mem.Allocator) void {
        allocator.free(self.txn_signature);
    }
};

/// Signer entry for SignerListSet
pub const SignerEntry = struct {
    account: types.AccountID,
    signer_weight: u16,
};

/// SignerListSet Transaction (BLOCKER #3 FIX)
pub const SignerListSet = struct {
    base: types.Transaction,
    signer_quorum: u32,
    signer_entries: []const SignerEntry,

    pub fn create(
        account: types.AccountID,
        signer_quorum: u32,
        signer_entries: []const SignerEntry,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) SignerListSet {
        return SignerListSet{
            .base = types.Transaction{
                .tx_type = .signer_list_set,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .signer_quorum = signer_quorum,
            .signer_entries = signer_entries,
        };
    }

    pub fn validate(self: *const SignerListSet) !void {
        // Quorum must be > 0
        if (self.signer_quorum == 0) return error.InvalidQuorum;

        // Must have signers
        if (self.signer_entries.len == 0) return error.NoSigners;
        if (self.signer_entries.len > 32) return error.TooManySigners;

        // Total weight must be >= quorum
        var total_weight: u32 = 0;
        for (self.signer_entries) |entry| {
            total_weight += entry.signer_weight;
        }

        if (total_weight < self.signer_quorum) {
            return error.InsufficientSignerWeight;
        }

        // No duplicate accounts
        for (self.signer_entries, 0..) |entry1, i| {
            for (self.signer_entries[i + 1 ..]) |entry2| {
                if (std.mem.eql(u8, &entry1.account, &entry2.account)) {
                    return error.DuplicateSigner;
                }
            }
        }
    }
};

/// Verify multi-signature transaction
pub fn verifyMultiSig(
    tx_hash: [32]u8,
    signers: []const Signer,
    signer_entries: []const SignerEntry,
    quorum: u32,
) !bool {
    // Verify each signature
    var total_weight: u32 = 0;

    for (signers) |signer| {
        // Find matching entry
        const weight = for (signer_entries) |entry| {
            if (std.mem.eql(u8, &entry.account, &signer.account)) {
                break entry.signer_weight;
            }
        } else {
            return error.SignerNotInList;
        };

        // Verify signature (using secp256k1 or Ed25519 based on key format)
        const valid = try verifySignerSignature(&tx_hash, &signer.signing_pub_key, signer.txn_signature);

        if (valid) {
            total_weight += weight;
        }
    }

    // Check if quorum reached
    return total_weight >= quorum;
}

fn verifySignerSignature(tx_hash: *const [32]u8, pub_key: *const [33]u8, signature: []const u8) !bool {
    // Determine key type from prefix
    if (pub_key[0] == 0xED) {
        // Ed25519
        if (signature.len != 64) return false;

        var ed_pub_key: [32]u8 = undefined;
        @memcpy(&ed_pub_key, pub_key[1..33]);

        var sig_bytes: [64]u8 = undefined;
        @memcpy(&sig_bytes, signature[0..64]);

        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
        const pub_key_struct = try std.crypto.sign.Ed25519.PublicKey.fromBytes(ed_pub_key);

        // Verify signature using Signature.verify method (Zig 0.14.1 API)
        sig.verify(tx_hash, pub_key_struct) catch return false;
        return true;
    } else if (pub_key[0] == 0x02 or pub_key[0] == 0x03) {
        // secp256k1
        const secp = @import("secp256k1.zig");
        return secp.verifySignature(pub_key, tx_hash, signature) catch false;
    }

    return error.UnknownKeyType;
}

test "signer list set validation" {
    const account = [_]u8{1} ** 20;

    const entries = [_]SignerEntry{
        .{ .account = [_]u8{2} ** 20, .signer_weight = 1 },
        .{ .account = [_]u8{3} ** 20, .signer_weight = 1 },
        .{ .account = [_]u8{4} ** 20, .signer_weight = 1 },
    };

    const tx = SignerListSet.create(
        account,
        2, // Quorum: need 2 signers
        &entries,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try tx.validate();

    std.debug.print("[PASS] SignerListSet transaction validates\n", .{});
    std.debug.print("   Signers: {d}, Quorum: {d}\n", .{ entries.len, tx.signer_quorum });
}

test "multi-sig quorum validation" {
    const account = [_]u8{1} ** 20;

    const entries = [_]SignerEntry{
        .{ .account = [_]u8{2} ** 20, .signer_weight = 1 },
    };

    const tx = SignerListSet.create(
        account,
        5, // Quorum too high!
        &entries,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try std.testing.expectError(error.InsufficientSignerWeight, tx.validate());

    std.debug.print("[PASS] Multi-sig quorum validation works\n", .{});
}
