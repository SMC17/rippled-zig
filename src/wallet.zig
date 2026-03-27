const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const base58 = @import("base58.zig");
const secp256k1_binding = @import("secp256k1_binding.zig");

/// XRPL Wallet — key derivation, address generation, and transaction signing.
///
/// Supports both secp256k1 (default, Bitcoin-style) and Ed25519 key algorithms.
///
/// Key derivation follows the XRPL specification:
///   - Seed: 16 random bytes
///   - Seed encoding: base58check with type prefix 0x21 ("sXXXXX" format)
///   - secp256k1: private_key = SHA-512-Half(seed ++ sequence_bytes), must be valid scalar
///   - Ed25519:  raw_key = SHA-512-Half(seed), used as Ed25519 seed
///   - Account ID: RIPEMD160(SHA256(public_key))
///   - Address: base58check with type prefix 0x00 ("rXXXXX" format)
pub const Wallet = struct {
    /// Raw 16-byte seed entropy.
    seed: [16]u8,
    /// Signing algorithm for this wallet.
    algorithm: crypto.SignatureAlgorithm,
    /// 20-byte account identifier derived from the public key.
    account_id: types.AccountID,

    // -- secp256k1 key material --
    secp256k1_private_key: ?[32]u8 = null,
    secp256k1_public_key: ?[33]u8 = null,

    // -- Ed25519 key material --
    ed25519_keypair: ?std.crypto.sign.Ed25519.KeyPair = null,

    // ----------------------------------------------------------------
    // Construction helpers
    // ----------------------------------------------------------------

    /// Generate a brand-new wallet with cryptographically random entropy.
    pub fn generate(algorithm: crypto.SignatureAlgorithm) !Wallet {
        var entropy: [16]u8 = undefined;
        std.crypto.random.bytes(&entropy);
        return fromEntropy(entropy, algorithm);
    }

    /// Create a wallet from raw 16-byte entropy (seed bytes).
    pub fn fromEntropy(entropy: [16]u8, algorithm: crypto.SignatureAlgorithm) !Wallet {
        return switch (algorithm) {
            .secp256k1 => try deriveSecp256k1(entropy),
            .ed25519 => try deriveEd25519(entropy),
        };
    }

    /// Restore a wallet from its base58check-encoded seed string ("sXXXXX").
    ///
    /// If `algorithm` is null the function uses the XRPL "sEd" prefix heuristic:
    /// seeds whose base58 encoding starts with "sEd" are treated as Ed25519,
    /// everything else as secp256k1.  Pass an explicit algorithm to override.
    pub fn fromSeed(seed_string: []const u8, allocator: std.mem.Allocator) !Wallet {
        return fromSeedWithAlgorithm(seed_string, null, allocator);
    }

    /// Like `fromSeed` but with an explicit algorithm override.
    pub fn fromSeedWithAlgorithm(seed_string: []const u8, algorithm_override: ?crypto.SignatureAlgorithm, allocator: std.mem.Allocator) !Wallet {
        const decoded = try base58.Base58.decode(allocator, seed_string);
        defer allocator.free(decoded);

        // Encoded seed: 1 byte type prefix (0x21) + 16 bytes payload + 4 bytes checksum = 21 bytes
        if (decoded.len != 21) return error.InvalidSeedLength;
        if (decoded[0] != 0x21) return error.InvalidSeedPrefix;

        // Verify checksum
        var hash1: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(decoded[0..17], &hash1, .{});
        var hash2: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&hash1, &hash2, .{});
        if (!std.mem.eql(u8, decoded[17..21], hash2[0..4])) {
            return error.InvalidChecksum;
        }

        var entropy: [16]u8 = undefined;
        @memcpy(&entropy, decoded[1..17]);

        const algorithm: crypto.SignatureAlgorithm = algorithm_override orelse
            if (seed_string.len >= 3 and std.mem.eql(u8, seed_string[0..3], "sEd"))
            .ed25519
        else
            .secp256k1;

        return fromEntropy(entropy, algorithm);
    }

    // ----------------------------------------------------------------
    // Seed encoding
    // ----------------------------------------------------------------

    /// Encode the wallet seed as a base58check string ("sXXXXX").
    pub fn encodeSeed(self: Wallet, allocator: std.mem.Allocator) ![]u8 {
        var data: [21]u8 = undefined;
        data[0] = 0x21; // seed type prefix
        @memcpy(data[1..17], &self.seed);

        // Double-SHA256 checksum
        var hash1: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data[0..17], &hash1, .{});
        var hash2: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&hash1, &hash2, .{});
        @memcpy(data[17..21], hash2[0..4]);

        return base58.Base58.encode(allocator, &data);
    }

    // ----------------------------------------------------------------
    // Address
    // ----------------------------------------------------------------

    /// Return the classic "rXXXXX" address for this wallet.
    pub fn address(self: Wallet, allocator: std.mem.Allocator) ![]u8 {
        return base58.Base58.encodeAccountID(allocator, self.account_id);
    }

    // ----------------------------------------------------------------
    // Public key accessors
    // ----------------------------------------------------------------

    /// Return the public key bytes.
    /// secp256k1 => 33 bytes (compressed), Ed25519 => 33 bytes (0xED prefix + 32-byte key).
    pub fn publicKey(self: Wallet) [33]u8 {
        return switch (self.algorithm) {
            .secp256k1 => self.secp256k1_public_key.?,
            .ed25519 => blk: {
                var buf: [33]u8 = undefined;
                buf[0] = 0xED; // XRPL Ed25519 public key prefix
                const kp = self.ed25519_keypair.?;
                @memcpy(buf[1..33], &kp.public_key.toBytes());
                break :blk buf;
            },
        };
    }

    // ----------------------------------------------------------------
    // Signing / verification
    // ----------------------------------------------------------------

    /// Sign arbitrary bytes (e.g. a transaction signing hash).
    /// Returns the raw signature bytes (caller owns the allocation).
    pub fn sign(self: Wallet, data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.algorithm) {
            .secp256k1 => {
                const seckey = self.secp256k1_private_key.?;

                // If data is already 32 bytes, treat as a hash; otherwise SHA-512-Half it.
                var msg_hash: [32]u8 = undefined;
                if (data.len == 32) {
                    @memcpy(&msg_hash, data);
                } else {
                    msg_hash = crypto.Hash.sha512Half(data);
                }

                return secp256k1_binding.signMessage(seckey, msg_hash, allocator);
            },
            .ed25519 => {
                const kp = self.ed25519_keypair.?;
                const sig = try kp.sign(data, null);
                const sig_bytes = sig.toBytes();
                return allocator.dupe(u8, &sig_bytes);
            },
        };
    }

    /// Verify a signature against the wallet's public key.
    pub fn verify(self: Wallet, data: []const u8, signature: []const u8) !bool {
        return switch (self.algorithm) {
            .secp256k1 => {
                var msg_hash: [32]u8 = undefined;
                if (data.len == 32) {
                    @memcpy(&msg_hash, data);
                } else {
                    msg_hash = crypto.Hash.sha512Half(data);
                }
                const pubkey = self.secp256k1_public_key.?;
                return secp256k1_binding.verifySignature(&pubkey, msg_hash, signature);
            },
            .ed25519 => {
                const kp = self.ed25519_keypair.?;
                if (signature.len != 64) return false;
                var sig_bytes: [64]u8 = undefined;
                @memcpy(&sig_bytes, signature);
                const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
                sig.verify(data, kp.public_key) catch return false;
                return true;
            },
        };
    }

    // ----------------------------------------------------------------
    // Internal derivation
    // ----------------------------------------------------------------

    /// secp256k1 key derivation per XRPL spec.
    ///
    /// root_private_key = SHA-512-Half(seed ++ 0x00000000)
    /// If the resulting 32-byte scalar is zero or >= group order, increment the
    /// 4-byte sequence counter and retry.
    fn deriveSecp256k1(seed: [16]u8) !Wallet {
        var seq: u32 = 0;
        while (seq < 10) : (seq += 1) {
            var buf: [20]u8 = undefined;
            @memcpy(buf[0..16], &seed);
            std.mem.writeInt(u32, buf[16..20], seq, .big);

            const private_key = crypto.Hash.sha512Half(&buf);

            // Validate that the key is a legal secp256k1 scalar
            const valid = secp256k1_binding.verifySecretKey(private_key) catch false;
            if (!valid) continue;

            const public_key = try secp256k1_binding.derivePublicKey(private_key);
            const account_id = crypto.Hash.accountID(&public_key);

            return Wallet{
                .seed = seed,
                .algorithm = .secp256k1,
                .account_id = account_id,
                .secp256k1_private_key = private_key,
                .secp256k1_public_key = public_key,
            };
        }
        return error.KeyDerivationFailed;
    }

    /// Ed25519 key derivation per XRPL spec.
    ///
    /// raw_key = SHA-512-Half(seed)
    /// The 32-byte result is used directly as the Ed25519 seed.
    fn deriveEd25519(seed: [16]u8) !Wallet {
        const raw_key = crypto.Hash.sha512Half(&seed);
        const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(raw_key);

        // XRPL Ed25519 public keys are prefixed with 0xED for account ID derivation
        var prefixed_pub: [33]u8 = undefined;
        prefixed_pub[0] = 0xED;
        @memcpy(prefixed_pub[1..33], &kp.public_key.toBytes());

        const account_id = crypto.Hash.accountID(&prefixed_pub);

        return Wallet{
            .seed = seed,
            .algorithm = .ed25519,
            .account_id = account_id,
            .ed25519_keypair = kp,
        };
    }
};

// =====================================================================
// Tests
// =====================================================================

test "wallet generate ed25519" {
    const w = try Wallet.generate(.ed25519);
    const allocator = std.testing.allocator;

    const addr = try w.address(allocator);
    defer allocator.free(addr);

    // Address must start with 'r'
    try std.testing.expect(addr[0] == 'r');
    try std.testing.expect(addr.len >= 25);

    // Public key must start with 0xED
    const pub_key = w.publicKey();
    try std.testing.expectEqual(@as(u8, 0xED), pub_key[0]);
}

test "wallet generate secp256k1" {
    const w = try Wallet.generate(.secp256k1);
    const allocator = std.testing.allocator;

    const addr = try w.address(allocator);
    defer allocator.free(addr);

    try std.testing.expect(addr[0] == 'r');
    try std.testing.expect(addr.len >= 25);

    // Compressed public key must start with 0x02 or 0x03
    const pub_key = w.publicKey();
    try std.testing.expect(pub_key[0] == 0x02 or pub_key[0] == 0x03);
}

test "wallet fromEntropy deterministic" {
    const entropy = [16]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };

    const w1 = try Wallet.fromEntropy(entropy, .ed25519);
    const w2 = try Wallet.fromEntropy(entropy, .ed25519);

    try std.testing.expectEqualSlices(u8, &w1.account_id, &w2.account_id);

    const allocator = std.testing.allocator;
    const addr1 = try w1.address(allocator);
    defer allocator.free(addr1);
    const addr2 = try w2.address(allocator);
    defer allocator.free(addr2);

    try std.testing.expectEqualStrings(addr1, addr2);
}

test "wallet fromEntropy secp256k1 deterministic" {
    const entropy = [16]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10 };

    const w1 = try Wallet.fromEntropy(entropy, .secp256k1);
    const w2 = try Wallet.fromEntropy(entropy, .secp256k1);

    try std.testing.expectEqualSlices(u8, &w1.account_id, &w2.account_id);
    try std.testing.expectEqualSlices(u8, &w1.secp256k1_public_key.?, &w2.secp256k1_public_key.?);
    try std.testing.expectEqualSlices(u8, &w1.secp256k1_private_key.?, &w2.secp256k1_private_key.?);
}

test "wallet seed encode/decode round-trip ed25519" {
    const allocator = std.testing.allocator;
    const w1 = try Wallet.generate(.ed25519);

    const seed_str = try w1.encodeSeed(allocator);
    defer allocator.free(seed_str);

    // Seed must start with 's'
    try std.testing.expect(seed_str[0] == 's');

    // Round-trip: decode the seed string and re-derive the wallet (explicit algorithm)
    const w2 = try Wallet.fromSeedWithAlgorithm(seed_str, .ed25519, allocator);
    try std.testing.expectEqualSlices(u8, &w1.account_id, &w2.account_id);
}

test "wallet seed encode/decode round-trip secp256k1" {
    const allocator = std.testing.allocator;
    const w1 = try Wallet.generate(.secp256k1);

    const seed_str = try w1.encodeSeed(allocator);
    defer allocator.free(seed_str);

    try std.testing.expect(seed_str[0] == 's');

    // Round-trip with explicit algorithm
    const w2 = try Wallet.fromSeedWithAlgorithm(seed_str, .secp256k1, allocator);
    try std.testing.expectEqualSlices(u8, &w1.account_id, &w2.account_id);
    try std.testing.expectEqualSlices(u8, &w1.secp256k1_private_key.?, &w2.secp256k1_private_key.?);
}

test "wallet ed25519 sign and verify" {
    const allocator = std.testing.allocator;
    const w = try Wallet.generate(.ed25519);

    const message = "XRPL transaction payload";
    const sig = try w.sign(message, allocator);
    defer allocator.free(sig);

    try std.testing.expect(sig.len == 64);
    try std.testing.expect(try w.verify(message, sig));

    // Tampered message must fail
    try std.testing.expect(!try w.verify("tampered payload", sig));
}

test "wallet secp256k1 sign and verify" {
    const allocator = std.testing.allocator;
    const w = try Wallet.generate(.secp256k1);

    const message = "XRPL transaction payload for secp256k1";
    const sig = try w.sign(message, allocator);
    defer allocator.free(sig);

    // DER signature starts with 0x30
    try std.testing.expect(sig[0] == 0x30);
    try std.testing.expect(try w.verify(message, sig));
}

test "wallet account ID matches crypto.Hash.accountID" {
    const w = try Wallet.generate(.ed25519);
    const pub_key = w.publicKey();
    const expected_id = crypto.Hash.accountID(&pub_key);
    try std.testing.expectEqualSlices(u8, &expected_id, &w.account_id);
}

test "wallet different entropy produces different addresses" {
    const allocator = std.testing.allocator;
    const e1 = [16]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F };
    const e2 = [16]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F };

    const w1 = try Wallet.fromEntropy(e1, .ed25519);
    const w2 = try Wallet.fromEntropy(e2, .ed25519);

    const a1 = try w1.address(allocator);
    defer allocator.free(a1);
    const a2 = try w2.address(allocator);
    defer allocator.free(a2);

    try std.testing.expect(!std.mem.eql(u8, a1, a2));
}
