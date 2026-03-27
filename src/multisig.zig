const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");

/// Return the number of bytes needed to VL-encode a given length.
/// XRPL variable-length encoding: 1 byte for len < 193, 2 bytes for len < 12481, 3 otherwise.
fn vlEncodedSize(len: usize) usize {
    if (len < 193) return 1;
    if (len < 12481) return 2;
    return 3;
}

/// Multi-Signature Support for XRPL
///
/// XRPL multi-signing allows a transaction to be authorized by a weighted
/// combination of signers instead of a single master key.  Each signer
/// signs a hash that includes their own AccountID (preventing replay across
/// signers), and the quorum is satisfied when the sum of valid signer
/// weights meets or exceeds the threshold.

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Multi-sign prefix: "SMT\0" — used instead of "STX\0" for single-sign.
pub const SMT_PREFIX = [_]u8{ 0x53, 0x4D, 0x54, 0x00 };

/// Single-sign prefix (re-exported from crypto for convenience in tests).
pub const STX_PREFIX = crypto.Hash.STX_PREFIX;

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Signer for multi-signature transaction.
/// Represents one participant's signature on a multi-signed tx.
pub const Signer = struct {
    account: types.AccountID,
    signing_pub_key: [33]u8,
    txn_signature: []const u8,

    pub fn deinit(self: *Signer, allocator: std.mem.Allocator) void {
        allocator.free(self.txn_signature);
    }
};

/// Signer entry for SignerListSet — a (account, weight) pair.
pub const SignerEntry = struct {
    account: types.AccountID,
    signer_weight: u16,
};

/// A signer list with a quorum threshold.
/// The list may contain 1-32 entries; each entry has a non-zero weight
/// and the total weight must be >= quorum.
pub const SignerList = struct {
    entries: []const SignerEntry,
    quorum: u32,

    /// Validate the signer list according to XRPL rules.
    pub fn validate(self: SignerList) !void {
        if (self.quorum == 0) return error.InvalidQuorum;
        if (self.entries.len == 0) return error.NoSigners;
        if (self.entries.len > 32) return error.TooManySigners;

        var total_weight: u32 = 0;
        for (self.entries) |entry| {
            if (entry.signer_weight == 0) return error.ZeroWeight;
            total_weight += entry.signer_weight;
        }

        if (total_weight < self.quorum) {
            return error.InsufficientSignerWeight;
        }

        // No duplicate accounts
        for (self.entries, 0..) |entry1, i| {
            for (self.entries[i + 1 ..]) |entry2| {
                if (std.mem.eql(u8, &entry1.account, &entry2.account)) {
                    return error.DuplicateSigner;
                }
            }
        }
    }

    /// Return true when the entries are in canonical (ascending AccountID) order.
    pub fn isSorted(self: SignerList) bool {
        if (self.entries.len <= 1) return true;
        for (0..self.entries.len - 1) |i| {
            if (accountOrder({}, self.entries[i + 1], self.entries[i])) {
                return false; // next < current means out of order
            }
        }
        return true;
    }

    /// Sort entries by AccountID in ascending order (canonical order).
    /// Requires a mutable slice — callers that own the backing memory should
    /// use `sortEntries()` on the mutable slice directly.
    pub fn sortEntries(entries: []SignerEntry) void {
        std.mem.sort(SignerEntry, entries, {}, accountOrder);
    }
};

/// Comparison function: true when a.account < b.account (lexicographic).
fn accountOrder(_: void, a: SignerEntry, b: SignerEntry) bool {
    return std.mem.order(u8, &a.account, &b.account) == .lt;
}

/// Comparison for Signer (used when sorting signers in a multi-signed tx).
fn signerAccountOrder(_: void, a: Signer, b: Signer) bool {
    return std.mem.order(u8, &a.account, &b.account) == .lt;
}

// ---------------------------------------------------------------------------
// SignerListSet transaction (legacy wrapper kept for backward compat)
// ---------------------------------------------------------------------------

/// SignerListSet Transaction
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
        const list = SignerList{
            .entries = self.signer_entries,
            .quorum = self.signer_quorum,
        };
        // SignerListSet allows zero-weight entries in the protocol (only
        // SignerList.validate enforces non-zero).  Use the legacy logic
        // so existing callers keep working.
        if (list.quorum == 0) return error.InvalidQuorum;
        if (list.entries.len == 0) return error.NoSigners;
        if (list.entries.len > 32) return error.TooManySigners;

        var total_weight: u32 = 0;
        for (list.entries) |entry| {
            total_weight += entry.signer_weight;
        }
        if (total_weight < list.quorum) return error.InsufficientSignerWeight;

        for (list.entries, 0..) |entry1, i| {
            for (list.entries[i + 1 ..]) |entry2| {
                if (std.mem.eql(u8, &entry1.account, &entry2.account)) {
                    return error.DuplicateSigner;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Multi-sign hashing
// ---------------------------------------------------------------------------

/// Compute the multi-sign signing hash for a specific signer.
///
/// hash = SHA-512-Half( SMT_PREFIX || canonical_tx_bytes || signer_account_id )
///
/// Each signer signs a DIFFERENT hash because their AccountID is appended.
pub fn multiSignHash(canonical_tx_bytes: []const u8, signer_account: types.AccountID) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha512.init(.{});
    hasher.update(&SMT_PREFIX);
    hasher.update(canonical_tx_bytes);
    hasher.update(&signer_account);
    var full: [64]u8 = undefined;
    hasher.final(&full);
    var result: [32]u8 = undefined;
    @memcpy(&result, full[0..32]);
    return result;
}

/// Compute the single-sign signing hash (STX prefix, no account suffix).
/// Provided here for comparison in tests.
pub fn singleSignHash(canonical_tx_bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha512.init(.{});
    hasher.update(&STX_PREFIX);
    hasher.update(canonical_tx_bytes);
    var full: [64]u8 = undefined;
    hasher.final(&full);
    var result: [32]u8 = undefined;
    @memcpy(&result, full[0..32]);
    return result;
}

// ---------------------------------------------------------------------------
// Multi-sign verification
// ---------------------------------------------------------------------------

/// Verify a multi-signed transaction.
///
/// For each signer:
///   1. Compute the signer-specific hash (SMT prefix + tx bytes + signer account)
///   2. Verify the signature against that hash using the signer's public key
///   3. Look up the signer's weight in the signer list
///   4. Accumulate weight for valid signatures
///
/// Returns true when the accumulated weight >= quorum.
pub fn verifyMultiSig(
    canonical_tx_bytes: []const u8,
    signers: []const Signer,
    signer_list: SignerList,
) !bool {
    var total_weight: u32 = 0;

    for (signers) |signer| {
        // Find matching entry and weight
        const weight = for (signer_list.entries) |entry| {
            if (std.mem.eql(u8, &entry.account, &signer.account)) {
                break entry.signer_weight;
            }
        } else {
            return error.SignerNotInList;
        };

        // Compute the signer-specific hash
        const hash = multiSignHash(canonical_tx_bytes, signer.account);

        // Verify signature
        const valid = try verifySignerSignature(&hash, &signer.signing_pub_key, signer.txn_signature);

        if (valid) {
            total_weight += weight;
        }
    }

    return total_weight >= signer_list.quorum;
}

/// Legacy verifyMultiSig that takes a pre-computed tx_hash (kept for
/// backward compatibility but callers should prefer the canonical_tx_bytes
/// overload).
pub fn verifyMultiSigLegacy(
    tx_hash: [32]u8,
    signers: []const Signer,
    signer_entries: []const SignerEntry,
    quorum: u32,
) !bool {
    var total_weight: u32 = 0;

    for (signers) |signer| {
        const weight = for (signer_entries) |entry| {
            if (std.mem.eql(u8, &entry.account, &signer.account)) {
                break entry.signer_weight;
            }
        } else {
            return error.SignerNotInList;
        };

        const valid = try verifySignerSignature(&tx_hash, &signer.signing_pub_key, signer.txn_signature);

        if (valid) {
            total_weight += weight;
        }
    }

    return total_weight >= quorum;
}

fn verifySignerSignature(tx_hash: *const [32]u8, pub_key: *const [33]u8, signature: []const u8) !bool {
    if (pub_key[0] == 0xED) {
        // Ed25519
        if (signature.len != 64) return false;

        var ed_pub_key: [32]u8 = undefined;
        @memcpy(&ed_pub_key, pub_key[1..33]);

        var sig_bytes: [64]u8 = undefined;
        @memcpy(&sig_bytes, signature[0..64]);

        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
        const pub_key_struct = try std.crypto.sign.Ed25519.PublicKey.fromBytes(ed_pub_key);

        sig.verify(tx_hash, pub_key_struct) catch return false;
        return true;
    } else if (pub_key[0] == 0x02 or pub_key[0] == 0x03) {
        // secp256k1
        const secp = @import("secp256k1.zig");
        return secp.verifySignature(pub_key, tx_hash, signature) catch false;
    }

    return error.UnknownKeyType;
}

// ---------------------------------------------------------------------------
// Multi-sign transaction construction
// ---------------------------------------------------------------------------

/// XRPL serialization field header encoding.
fn encodeFieldHeader(buf: []u8, type_code: u8, field_code: u8) usize {
    if (type_code < 16 and field_code < 16) {
        buf[0] = (type_code << 4) | field_code;
        return 1;
    } else if (type_code < 16 and field_code >= 16) {
        buf[0] = type_code << 4;
        buf[1] = field_code;
        return 2;
    } else if (type_code >= 16 and field_code < 16) {
        buf[0] = field_code;
        buf[1] = type_code;
        return 2;
    } else {
        buf[0] = 0;
        buf[1] = type_code;
        buf[2] = field_code;
        return 3;
    }
}

/// Encode a variable-length prefix (VL encoding used by XRPL for Blob fields).
fn encodeVL(buf: []u8, length: usize) usize {
    if (length <= 192) {
        buf[0] = @intCast(length);
        return 1;
    } else if (length <= 12480) {
        const adjusted = length - 193;
        buf[0] = @intCast(193 + (adjusted >> 8));
        buf[1] = @intCast(adjusted & 0xFF);
        return 2;
    } else {
        const adjusted = length - 12481;
        buf[0] = @intCast(241 + (adjusted >> 16));
        buf[1] = @intCast((adjusted >> 8) & 0xFF);
        buf[2] = @intCast(adjusted & 0xFF);
        return 3;
    }
}

/// Build a multi-signed transaction blob.
///
/// Takes the canonical transaction bytes (without any signature fields) and
/// an array of Signers (each with account, pub key, and signature).
///
/// The output is:
///   canonical_bytes
///   + SigningPubKey (type=7/Blob, field=3) with zero-length VL
///   + Signers STArray (type=15, field=3)
///       each SignerEntry STObject (type=14, field=16):
///         Account (type=8, field=1)
///         SigningPubKey (type=7, field=3)
///         TxnSignature (type=7, field=4)
///         STObject end marker (0xE1)
///     STArray end marker (0xF1)
///
/// Signers are sorted by account ID in ascending order.
pub fn buildMultiSignedTx(
    allocator: std.mem.Allocator,
    canonical_bytes: []const u8,
    signers: []const Signer,
) ![]u8 {
    // Sort signers by account (we need a mutable copy)
    const sorted = try allocator.alloc(Signer, signers.len);
    defer allocator.free(sorted);
    @memcpy(sorted, signers);
    std.mem.sort(Signer, sorted, {}, signerAccountOrder);

    // Calculate required buffer size
    var extra_size: usize = 0;

    // SigningPubKey empty blob: field header + VL(0)
    extra_size += 2; // field header (type=7, field=3 -> 0x73) + VL byte (0x00)

    // Signers array header: field header for STArray field 3
    // type=15, field=3 -> (15 << 4) | 3 = 0xF3
    extra_size += 1;

    for (sorted) |signer| {
        // SignerEntry object header: type=14, field=16 -> (14 << 4) | 0, 16 -> 0xE0, 0x10
        extra_size += 2; // field header

        // Account: type=8, field=1 -> 0x81; VL(20) + 20 bytes
        extra_size += 1 + 1 + 20;

        // SigningPubKey: type=7, field=3 -> 0x73; VL(33) + 33 bytes
        extra_size += 1 + 1 + 33;

        // TxnSignature: type=7, field=4 -> 0x74; VL(sig.len) + sig bytes
        extra_size += 1 + vlEncodedSize(signer.txn_signature.len) + signer.txn_signature.len;

        // STObject end marker
        extra_size += 1; // 0xE1
    }

    // STArray end marker
    extra_size += 1; // 0xF1

    const result = try allocator.alloc(u8, canonical_bytes.len + extra_size);
    errdefer allocator.free(result);

    var pos: usize = 0;

    // Copy canonical bytes
    @memcpy(result[pos .. pos + canonical_bytes.len], canonical_bytes);
    pos += canonical_bytes.len;

    // SigningPubKey = empty blob (type=7/Blob, field=3)
    result[pos] = 0x73; // (7 << 4) | 3
    pos += 1;
    result[pos] = 0x00; // VL length = 0
    pos += 1;

    // Signers STArray (type=15, field=3)
    result[pos] = 0xF3; // (15 << 4) | 3
    pos += 1;

    for (sorted) |signer| {
        // SignerEntry STObject (type=14, field=16)
        // type=14 < 16, field=16 >= 16: two bytes -> (14 << 4) | 0, 16
        result[pos] = 0xE0;
        pos += 1;
        result[pos] = 0x10;
        pos += 1;

        // Account (type=8, field=1) -> 0x81
        result[pos] = 0x81;
        pos += 1;
        result[pos] = 20; // VL length
        pos += 1;
        @memcpy(result[pos .. pos + 20], &signer.account);
        pos += 20;

        // SigningPubKey (type=7, field=3) -> 0x73
        result[pos] = 0x73;
        pos += 1;
        result[pos] = 33; // VL length
        pos += 1;
        @memcpy(result[pos .. pos + 33], &signer.signing_pub_key);
        pos += 33;

        // TxnSignature (type=7, field=4) -> 0x74
        result[pos] = 0x74;
        pos += 1;
        const vl_len = encodeVL(result[pos..], signer.txn_signature.len);
        pos += vl_len;
        @memcpy(result[pos .. pos + signer.txn_signature.len], signer.txn_signature);
        pos += signer.txn_signature.len;

        // STObject end marker
        result[pos] = 0xE1;
        pos += 1;
    }

    // STArray end marker
    result[pos] = 0xF1;
    pos += 1;

    // Shrink to actual size (should match but be safe)
    if (pos != result.len) {
        const shrunk = try allocator.realloc(result, pos);
        return shrunk;
    }

    return result;
}

// ===========================================================================
// Tests
// ===========================================================================

test "create valid signer list with quorum" {
    const entries = [_]SignerEntry{
        .{ .account = [_]u8{2} ** 20, .signer_weight = 1 },
        .{ .account = [_]u8{3} ** 20, .signer_weight = 1 },
        .{ .account = [_]u8{4} ** 20, .signer_weight = 1 },
    };

    const list = SignerList{ .entries = &entries, .quorum = 2 };
    try list.validate();

    // Also validate through SignerListSet for backward compat
    const tx = SignerListSet.create(
        [_]u8{1} ** 20,
        2,
        &entries,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );
    try tx.validate();
}

test "reject signer list with total weight less than quorum" {
    const entries = [_]SignerEntry{
        .{ .account = [_]u8{2} ** 20, .signer_weight = 1 },
    };

    const list = SignerList{ .entries = &entries, .quorum = 5 };
    try std.testing.expectError(error.InsufficientSignerWeight, list.validate());
}

test "reject signer list with zero weight entry" {
    const entries = [_]SignerEntry{
        .{ .account = [_]u8{2} ** 20, .signer_weight = 0 },
        .{ .account = [_]u8{3} ** 20, .signer_weight = 2 },
    };

    const list = SignerList{ .entries = &entries, .quorum = 1 };
    try std.testing.expectError(error.ZeroWeight, list.validate());
}

test "multi-sign hash differs from single-sign hash" {
    const canonical = [_]u8{ 0x12, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x01 };
    const account = [_]u8{0xAA} ** 20;

    const multi_hash = multiSignHash(&canonical, account);
    const single_hash = singleSignHash(&canonical);

    // The two hashes MUST differ because of the different prefixes and
    // the appended account ID.
    try std.testing.expect(!std.mem.eql(u8, &multi_hash, &single_hash));
}

test "multi-sign hash includes signer account ID" {
    const canonical = [_]u8{ 0x12, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x01 };

    const account_a = [_]u8{0xAA} ** 20;
    const account_b = [_]u8{0xBB} ** 20;

    const hash_a = multiSignHash(&canonical, account_a);
    const hash_b = multiSignHash(&canonical, account_b);

    // Same tx bytes, different signer accounts -> different hashes
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_b));
}

test "verify multi-signed transaction with Ed25519 signers" {
    const allocator = std.testing.allocator;

    // Fake canonical tx bytes
    const canonical = [_]u8{ 0x12, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x01 };

    // Generate two Ed25519 key pairs
    const gen1 = crypto.Ed25519.generateKeyPair();
    const gen2 = crypto.Ed25519.generateKeyPair();

    const account1 = crypto.Ed25519.accountID(gen1.key_pair.public_key.toBytes());
    const account2 = crypto.Ed25519.accountID(gen2.key_pair.public_key.toBytes());

    // Each signer signs their own hash (SMT prefix + canonical + their account)
    const hash1 = multiSignHash(&canonical, account1);
    const hash2 = multiSignHash(&canonical, account2);

    const sig1 = try crypto.Ed25519.signMessage(gen1.key_pair, &hash1);
    const sig2 = try crypto.Ed25519.signMessage(gen2.key_pair, &hash2);

    const sig1_dupe = try allocator.dupe(u8, &sig1);
    defer allocator.free(sig1_dupe);
    const sig2_dupe = try allocator.dupe(u8, &sig2);
    defer allocator.free(sig2_dupe);

    const signer_entries = [_]SignerEntry{
        .{ .account = account1, .signer_weight = 1 },
        .{ .account = account2, .signer_weight = 1 },
    };

    const signers = [_]Signer{
        .{
            .account = account1,
            .signing_pub_key = gen1.xrpl_public_key,
            .txn_signature = sig1_dupe,
        },
        .{
            .account = account2,
            .signing_pub_key = gen2.xrpl_public_key,
            .txn_signature = sig2_dupe,
        },
    };

    const signer_list = SignerList{ .entries = &signer_entries, .quorum = 2 };

    const result = try verifyMultiSig(&canonical, &signers, signer_list);
    try std.testing.expect(result);
}

test "reject insufficient quorum when some signatures missing" {
    const allocator = std.testing.allocator;

    const canonical = [_]u8{ 0x12, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x01 };

    // Three signers in the list, quorum = 3, but only one signs
    const gen1 = crypto.Ed25519.generateKeyPair();
    const gen2 = crypto.Ed25519.generateKeyPair();
    const gen3 = crypto.Ed25519.generateKeyPair();

    const account1 = crypto.Ed25519.accountID(gen1.key_pair.public_key.toBytes());
    const account2 = crypto.Ed25519.accountID(gen2.key_pair.public_key.toBytes());
    const account3 = crypto.Ed25519.accountID(gen3.key_pair.public_key.toBytes());

    const hash1 = multiSignHash(&canonical, account1);
    const sig1 = try crypto.Ed25519.signMessage(gen1.key_pair, &hash1);

    const sig1_dupe = try allocator.dupe(u8, &sig1);
    defer allocator.free(sig1_dupe);

    const signer_entries = [_]SignerEntry{
        .{ .account = account1, .signer_weight = 1 },
        .{ .account = account2, .signer_weight = 1 },
        .{ .account = account3, .signer_weight = 1 },
    };

    // Only one signer provides a signature
    const signers = [_]Signer{
        .{
            .account = account1,
            .signing_pub_key = gen1.xrpl_public_key,
            .txn_signature = sig1_dupe,
        },
    };

    const signer_list = SignerList{ .entries = &signer_entries, .quorum = 3 };

    const result = try verifyMultiSig(&canonical, &signers, signer_list);
    try std.testing.expect(!result); // weight=1 < quorum=3
}

test "signer entries sorted by account ID" {
    // Create entries in descending order
    var entries = [_]SignerEntry{
        .{ .account = [_]u8{0xFF} ** 20, .signer_weight = 1 },
        .{ .account = [_]u8{0x55} ** 20, .signer_weight = 2 },
        .{ .account = [_]u8{0x11} ** 20, .signer_weight = 3 },
    };

    // They should NOT be sorted initially
    const list_unsorted = SignerList{ .entries = &entries, .quorum = 1 };
    try std.testing.expect(!list_unsorted.isSorted());

    // Sort them
    SignerList.sortEntries(&entries);

    // Now they should be in ascending order
    const list_sorted = SignerList{ .entries = &entries, .quorum = 1 };
    try std.testing.expect(list_sorted.isSorted());

    // Verify order: 0x11 < 0x55 < 0xFF
    try std.testing.expectEqual(@as(u8, 0x11), entries[0].account[0]);
    try std.testing.expectEqual(@as(u8, 0x55), entries[1].account[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), entries[2].account[0]);
}

test "buildMultiSignedTx produces valid structure" {
    const allocator = std.testing.allocator;

    const canonical = [_]u8{ 0x12, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x01 };

    const gen1 = crypto.Ed25519.generateKeyPair();
    const account1 = crypto.Ed25519.accountID(gen1.key_pair.public_key.toBytes());
    const hash1 = multiSignHash(&canonical, account1);
    const sig1 = try crypto.Ed25519.signMessage(gen1.key_pair, &hash1);

    const sig1_dupe = try allocator.dupe(u8, &sig1);
    defer allocator.free(sig1_dupe);

    const signers = [_]Signer{
        .{
            .account = account1,
            .signing_pub_key = gen1.xrpl_public_key,
            .txn_signature = sig1_dupe,
        },
    };

    const tx_blob = try buildMultiSignedTx(allocator, &canonical, &signers);
    defer allocator.free(tx_blob);

    // The blob must start with the canonical bytes
    try std.testing.expectEqualSlices(u8, &canonical, tx_blob[0..canonical.len]);

    // After canonical bytes: empty SigningPubKey (0x73, 0x00)
    try std.testing.expectEqual(@as(u8, 0x73), tx_blob[canonical.len]);
    try std.testing.expectEqual(@as(u8, 0x00), tx_blob[canonical.len + 1]);

    // Signers array header (0xF3)
    try std.testing.expectEqual(@as(u8, 0xF3), tx_blob[canonical.len + 2]);

    // The blob must end with the STArray end marker 0xF1
    try std.testing.expectEqual(@as(u8, 0xF1), tx_blob[tx_blob.len - 1]);
}

test "signer list set validation (legacy)" {
    const account = [_]u8{1} ** 20;

    const entries = [_]SignerEntry{
        .{ .account = [_]u8{2} ** 20, .signer_weight = 1 },
        .{ .account = [_]u8{3} ** 20, .signer_weight = 1 },
        .{ .account = [_]u8{4} ** 20, .signer_weight = 1 },
    };

    const tx = SignerListSet.create(
        account,
        2,
        &entries,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try tx.validate();
}

test "multi-sig quorum validation (legacy)" {
    const account = [_]u8{1} ** 20;

    const entries = [_]SignerEntry{
        .{ .account = [_]u8{2} ** 20, .signer_weight = 1 },
    };

    const tx = SignerListSet.create(
        account,
        5,
        &entries,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try std.testing.expectError(error.InsufficientSignerWeight, tx.validate());
}
