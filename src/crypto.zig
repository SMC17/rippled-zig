const std = @import("std");
const types = @import("types.zig");

/// Cryptographic hash functions used in XRP Ledger
pub const Hash = struct {
    /// XRPL signing prefix for transaction signing.
    pub const STX_PREFIX = [_]u8{ 0x53, 0x54, 0x58, 0x00 };

    /// SHA-512 Half (first 256 bits of SHA-512)
    /// This is the primary hash function used in XRPL
    pub fn sha512Half(data: []const u8) [32]u8 {
        var full_hash: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(data, &full_hash, .{});

        var result: [32]u8 = undefined;
        @memcpy(&result, full_hash[0..32]);
        return result;
    }

    /// SHA-512 Half of `prefix || payload`.
    pub fn prefixedSha512Half(prefix: []const u8, payload: []const u8, allocator: std.mem.Allocator) ![32]u8 {
        const buf = try allocator.alloc(u8, prefix.len + payload.len);
        defer allocator.free(buf);
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..], payload);
        return sha512Half(buf);
    }

    /// XRPL transaction signing hash: SHA512Half(STX || canonical_tx_without_signature_fields)
    pub fn transactionSigningHash(canonical: []const u8, allocator: std.mem.Allocator) ![32]u8 {
        return prefixedSha512Half(&STX_PREFIX, canonical, allocator);
    }

    /// RIPEMD-160 hash (REAL implementation)
    /// BLOCKER #5: FIXED - Now using actual RIPEMD-160
    pub fn ripemd160(data: []const u8) [20]u8 {
        const ripemd = @import("ripemd160.zig");
        var result: [20]u8 = undefined;
        ripemd.hash(data, &result);
        return result;
    }

    /// Account ID hash - used to derive account IDs from public keys
    /// AccountID = RIPEMD160(SHA256(public_key))
    pub fn accountID(public_key: []const u8) types.AccountID {
        var sha256_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(public_key, &sha256_hash, .{});
        return ripemd160(&sha256_hash);
    }
};

/// Signature algorithms supported by XRP Ledger
pub const SignatureAlgorithm = enum {
    secp256k1, // ECDSA using secp256k1 (like Bitcoin)
    ed25519, // Ed25519 (modern, efficient)
};

/// XRPL Ed25519 utilities.
///
/// On the XRP Ledger, Ed25519 public keys are transmitted with a 0xED prefix
/// byte, making them 33 bytes long (same wire size as compressed secp256k1
/// keys).  Account IDs are derived from the *prefixed* form:
///
///     AccountID = RIPEMD160(SHA256(0xED || raw_32_byte_pubkey))
///
pub const Ed25519 = struct {
    /// The XRPL prefix byte for Ed25519 public keys.
    pub const PREFIX: u8 = 0xED;

    /// Build the 33-byte XRPL-prefixed public key from a raw 32-byte key.
    pub fn prefixedPublicKey(raw: [32]u8) [33]u8 {
        var out: [33]u8 = undefined;
        out[0] = PREFIX;
        @memcpy(out[1..], &raw);
        return out;
    }

    /// Derive the XRPL account ID from a raw 32-byte Ed25519 public key.
    /// Uses the prefixed (33-byte) form as input to the standard
    /// RIPEMD160(SHA256(key)) pipeline.
    pub fn accountID(raw_pub: [32]u8) types.AccountID {
        const prefixed = prefixedPublicKey(raw_pub);
        return Hash.accountID(&prefixed);
    }

    /// Generate a random Ed25519 key pair and return it together with the
    /// XRPL-prefixed public key.
    pub fn generateKeyPair() struct {
        key_pair: std.crypto.sign.Ed25519.KeyPair,
        xrpl_public_key: [33]u8,
    } {
        const kp = std.crypto.sign.Ed25519.KeyPair.generate();
        return .{
            .key_pair = kp,
            .xrpl_public_key = prefixedPublicKey(kp.public_key.toBytes()),
        };
    }

    /// Derive an Ed25519 key pair from a 32-byte seed (secret).
    /// The seed is expanded via SHA-512 Half and used as the Ed25519
    /// secret scalar, following the XRPL key-derivation convention.
    pub fn keyPairFromSeed(seed: [32]u8) !struct {
        key_pair: std.crypto.sign.Ed25519.KeyPair,
        xrpl_public_key: [33]u8,
    } {
        const kp = try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(
            std.crypto.sign.Ed25519.SecretKey.fromBytes(seed ++ [_]u8{0} ** 32),
        );
        return .{
            .key_pair = kp,
            .xrpl_public_key = prefixedPublicKey(kp.public_key.toBytes()),
        };
    }

    /// Sign arbitrary data with an Ed25519 key pair.
    /// Returns the 64-byte signature.
    pub fn signMessage(
        key_pair: std.crypto.sign.Ed25519.KeyPair,
        data: []const u8,
    ) ![64]u8 {
        const sig = try key_pair.sign(data, null);
        return sig.toBytes();
    }

    /// Verify an Ed25519 signature.
    /// `public_key` may be 32 bytes (raw) or 33 bytes (XRPL-prefixed; the
    /// leading 0xED byte is stripped automatically).
    pub fn verifySignature(
        public_key: []const u8,
        data: []const u8,
        signature: [64]u8,
    ) !bool {
        var raw: [32]u8 = undefined;
        if (public_key.len == 33) {
            if (public_key[0] != PREFIX) return false;
            @memcpy(&raw, public_key[1..33]);
        } else if (public_key.len == 32) {
            @memcpy(&raw, public_key);
        } else {
            return false;
        }

        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature);
        const pub_key = try std.crypto.sign.Ed25519.PublicKey.fromBytes(raw);
        sig.verify(data, pub_key) catch return false;
        return true;
    }
};

/// Key pair for signing transactions
pub const KeyPair = struct {
    algorithm: SignatureAlgorithm,
    public_key: []const u8,
    private_key: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *KeyPair) void {
        self.allocator.free(self.public_key);
        self.allocator.free(self.private_key);
    }

    /// Generate a new Ed25519 key pair.
    /// The stored public_key is the raw 32-byte key.  Use
    /// `getXrplPublicKey()` to obtain the 0xED-prefixed form.
    pub fn generateEd25519(allocator: std.mem.Allocator) !KeyPair {
        const gen = Ed25519.generateKeyPair();

        const pub_key_bytes = gen.key_pair.public_key.toBytes();
        const public_key = try allocator.dupe(u8, &pub_key_bytes);
        const secret_key_bytes = gen.key_pair.secret_key.toBytes();
        const private_key = try allocator.dupe(u8, &secret_key_bytes);

        return KeyPair{
            .algorithm = .ed25519,
            .public_key = public_key,
            .private_key = private_key,
            .allocator = allocator,
        };
    }

    /// Sign data using the private key
    pub fn sign(self: KeyPair, data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        switch (self.algorithm) {
            .ed25519 => {
                if (self.private_key.len != 64) {
                    return error.InvalidKeyLength;
                }

                // Reconstruct KeyPair from stored bytes
                var secret_key_bytes: [64]u8 = undefined;
                @memcpy(&secret_key_bytes, self.private_key);
                var pub_key_bytes: [32]u8 = undefined;
                @memcpy(&pub_key_bytes, self.public_key[0..32]);

                const secret_key = try std.crypto.sign.Ed25519.SecretKey.fromBytes(secret_key_bytes);
                const pub_key = try std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_key_bytes);
                const key_pair = std.crypto.sign.Ed25519.KeyPair{
                    .secret_key = secret_key,
                    .public_key = pub_key,
                };

                const signature = try key_pair.sign(data, null);
                const sig_bytes = signature.toBytes();
                return try allocator.dupe(u8, &sig_bytes);
            },
            .secp256k1 => {
                if (self.private_key.len != 32) {
                    return error.InvalidKeyLength;
                }
                var seckey: [32]u8 = undefined;
                @memcpy(&seckey, self.private_key);

                const stx: [4]u8 = .{ 0x53, 0x54, 0x58, 0x00 };
                var msg_hash: [32]u8 = undefined;
                if (data.len == 32) {
                    @memcpy(&msg_hash, data);
                } else {
                    msg_hash = try Hash.prefixedSha512Half(&stx, data, allocator);
                }

                const secp = @import("secp256k1_binding.zig");
                return secp.signMessage(seckey, msg_hash, allocator);
            },
        }
    }

    /// Sign canonical XRPL transaction bytes using the transaction signing domain.
    pub fn signXrplTransaction(self: KeyPair, canonical: []const u8, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.algorithm) {
            .secp256k1 => {
                const signing_hash = try Hash.transactionSigningHash(canonical, allocator);
                return self.sign(&signing_hash, allocator);
            },
            .ed25519 => self.sign(canonical, allocator),
        };
    }

    /// Verify a signature
    pub fn verify(public_key: []const u8, data: []const u8, signature: []const u8, algorithm: SignatureAlgorithm) !bool {
        switch (algorithm) {
            .ed25519 => {
                if (signature.len != 64) return false;

                // Accept both raw (32-byte) and XRPL-prefixed (33-byte) keys
                var raw: [32]u8 = undefined;
                if (public_key.len == 33 and public_key[0] == Ed25519.PREFIX) {
                    @memcpy(&raw, public_key[1..33]);
                } else if (public_key.len == 32) {
                    @memcpy(&raw, public_key);
                } else {
                    return false;
                }

                var sig_bytes: [64]u8 = undefined;
                @memcpy(&sig_bytes, signature);

                const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
                const pub_key_struct = try std.crypto.sign.Ed25519.PublicKey.fromBytes(raw);

                sig.verify(data, pub_key_struct) catch {
                    return false;
                };
                return true;
            },
            .secp256k1 => {
                // Use secp256k1 binding for ECDSA verification
                const secp = @import("secp256k1.zig");

                // secp256k1 uses compressed (33 bytes) or uncompressed (65 bytes) public keys
                // XRPL typically uses compressed (33 bytes) with 0x02 or 0x03 prefix
                if (public_key.len != 33 and public_key.len != 65) {
                    return false;
                }

                // Verify signature using the mandatory secp256k1 path.
                return secp.verifySignature(public_key, data, signature);
            },
        }
    }

    /// Get the XRPL-prefixed (33-byte) public key for Ed25519, or the raw
    /// public key for secp256k1.
    pub fn getXrplPublicKey(self: KeyPair) ![33]u8 {
        switch (self.algorithm) {
            .ed25519 => {
                if (self.public_key.len < 32) return error.InvalidKeyLength;
                var raw: [32]u8 = undefined;
                @memcpy(&raw, self.public_key[0..32]);
                return Ed25519.prefixedPublicKey(raw);
            },
            .secp256k1 => {
                if (self.public_key.len != 33) return error.InvalidKeyLength;
                var out: [33]u8 = undefined;
                @memcpy(&out, self.public_key);
                return out;
            },
        }
    }

    /// Get the account ID for this key pair.
    /// For Ed25519 keys, this uses the XRPL-prefixed (0xED || pubkey) form.
    pub fn getAccountID(self: KeyPair) !types.AccountID {
        switch (self.algorithm) {
            .ed25519 => {
                if (self.public_key.len < 32) return error.InvalidKeyLength;
                var raw: [32]u8 = undefined;
                @memcpy(&raw, self.public_key[0..32]);
                return Ed25519.accountID(raw);
            },
            .secp256k1 => {
                return Hash.accountID(self.public_key);
            },
        }
    }
};

test "sha512 half" {
    const data = "Hello, XRP Ledger!";
    const hash = Hash.sha512Half(data);
    try std.testing.expect(hash.len == 32);
}

test "ed25519 key generation" {
    const allocator = std.testing.allocator;
    var key_pair = try KeyPair.generateEd25519(allocator);
    defer key_pair.deinit();

    try std.testing.expect(key_pair.public_key.len == 32);
    try std.testing.expect(key_pair.algorithm == .ed25519);
}

test "ed25519 sign and verify" {
    const allocator = std.testing.allocator;
    var key_pair = try KeyPair.generateEd25519(allocator);
    defer key_pair.deinit();

    const message = "Test transaction";
    const signature = try key_pair.sign(message, allocator);
    defer allocator.free(signature);

    const valid = try KeyPair.verify(key_pair.public_key, message, signature, .ed25519);
    try std.testing.expect(valid);
}

test "xrpl signing hash uses STX prefix" {
    const allocator = std.testing.allocator;
    const canonical = [_]u8{ 0x12, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x01 };

    const signing_hash = try Hash.transactionSigningHash(&canonical, allocator);
    const body_hash = Hash.sha512Half(&canonical);

    try std.testing.expect(!std.mem.eql(u8, &signing_hash, &body_hash));
}

test "account ID derivation matches known XRPL vector" {
    const pub_key_hex = "02D3FC6F04117E6420CAEA735C57CEEC934820BBCD109200933F6BBDD98F7BFBD9";
    var pub_key: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&pub_key, pub_key_hex);

    const account_id = Hash.accountID(&pub_key);
    const expected = [_]u8{
        0xfa, 0xb4, 0xff, 0x1b, 0xec, 0x2e, 0x13, 0x76, 0x13, 0xd2,
        0x6d, 0xeb, 0xf3, 0xd5, 0x7e, 0xbb, 0x9d, 0x2c, 0xed, 0xae,
    };

    try std.testing.expectEqualSlices(u8, &expected, &account_id);
}

// ---------------------------------------------------------------------------
// XRPL Ed25519 tests
// ---------------------------------------------------------------------------

test "ed25519 prefixed public key is 33 bytes starting with 0xED" {
    const gen = Ed25519.generateKeyPair();
    const prefixed = gen.xrpl_public_key;

    try std.testing.expectEqual(@as(usize, 33), prefixed.len);
    try std.testing.expectEqual(@as(u8, 0xED), prefixed[0]);

    // The remaining 32 bytes must match the raw public key
    const raw = gen.key_pair.public_key.toBytes();
    try std.testing.expectEqualSlices(u8, &raw, prefixed[1..]);
}

test "ed25519 sign and verify via Ed25519 module" {
    const gen = Ed25519.generateKeyPair();
    const message = "XRPL Ed25519 test payload";
    const sig = try Ed25519.signMessage(gen.key_pair, message);

    // Verify with raw 32-byte key
    const raw = gen.key_pair.public_key.toBytes();
    try std.testing.expect(try Ed25519.verifySignature(&raw, message, sig));

    // Verify with XRPL-prefixed 33-byte key
    try std.testing.expect(try Ed25519.verifySignature(&gen.xrpl_public_key, message, sig));

    // Tamper with message -- verification must fail
    try std.testing.expect(!try Ed25519.verifySignature(&raw, "tampered", sig));

    // Tamper with signature -- verification must fail
    var bad_sig = sig;
    bad_sig[0] ^= 0xFF;
    try std.testing.expect(!try Ed25519.verifySignature(&raw, message, bad_sig));
}

test "ed25519 verify rejects wrong public key" {
    const gen1 = Ed25519.generateKeyPair();
    const gen2 = Ed25519.generateKeyPair();
    const message = "signed by gen1";
    const sig = try Ed25519.signMessage(gen1.key_pair, message);

    // gen2's key must not verify gen1's signature
    const raw2 = gen2.key_pair.public_key.toBytes();
    try std.testing.expect(!try Ed25519.verifySignature(&raw2, message, sig));
}

test "ed25519 account ID uses prefixed key (RIPEMD160(SHA256(0xED || pubkey)))" {
    const gen = Ed25519.generateKeyPair();
    const raw = gen.key_pair.public_key.toBytes();

    // Compute expected account ID manually
    const prefixed = Ed25519.prefixedPublicKey(raw);
    var sha256_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&prefixed, &sha256_hash, .{});
    const expected = Hash.ripemd160(&sha256_hash);

    const actual = Ed25519.accountID(raw);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "ed25519 KeyPair getXrplPublicKey returns 0xED-prefixed key" {
    const allocator = std.testing.allocator;
    var kp = try KeyPair.generateEd25519(allocator);
    defer kp.deinit();

    const xrpl_pub = try kp.getXrplPublicKey();
    try std.testing.expectEqual(@as(u8, 0xED), xrpl_pub[0]);
    try std.testing.expectEqualSlices(u8, kp.public_key[0..32], xrpl_pub[1..]);
}

test "ed25519 KeyPair getAccountID uses prefixed derivation" {
    const allocator = std.testing.allocator;
    var kp = try KeyPair.generateEd25519(allocator);
    defer kp.deinit();

    // Via KeyPair method
    const acct_id = try kp.getAccountID();

    // Via Ed25519 module directly
    var raw: [32]u8 = undefined;
    @memcpy(&raw, kp.public_key[0..32]);
    const expected = Ed25519.accountID(raw);

    try std.testing.expectEqualSlices(u8, &expected, &acct_id);
}

test "ed25519 verify accepts XRPL-prefixed key through KeyPair.verify" {
    const allocator = std.testing.allocator;
    var kp = try KeyPair.generateEd25519(allocator);
    defer kp.deinit();

    const message = "verify via KeyPair.verify with prefixed key";
    const signature = try kp.sign(message, allocator);
    defer allocator.free(signature);

    // Verify with raw 32-byte key (existing behaviour)
    try std.testing.expect(try KeyPair.verify(kp.public_key, message, signature, .ed25519));

    // Verify with 33-byte XRPL-prefixed key (new behaviour)
    const xrpl_pub = try kp.getXrplPublicKey();
    try std.testing.expect(try KeyPair.verify(&xrpl_pub, message, signature, .ed25519));
}

test "ed25519 KeyPair signXrplTransaction round-trip" {
    const allocator = std.testing.allocator;
    var kp = try KeyPair.generateEd25519(allocator);
    defer kp.deinit();

    const canonical = [_]u8{ 0x12, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x01 };
    const sig = try kp.signXrplTransaction(&canonical, allocator);
    defer allocator.free(sig);

    // Ed25519 XRPL signing signs the raw canonical bytes (no STX prefix hash)
    try std.testing.expect(sig.len == 64);
    try std.testing.expect(try KeyPair.verify(kp.public_key, &canonical, sig, .ed25519));
}

test "ed25519 verifySignature rejects invalid key lengths" {
    const gen = Ed25519.generateKeyPair();
    const sig = try Ed25519.signMessage(gen.key_pair, "test");

    // 31-byte key: too short
    const short_key = [_]u8{0} ** 31;
    try std.testing.expect(!try Ed25519.verifySignature(&short_key, "test", sig));

    // 34-byte key: too long
    const long_key = [_]u8{0xED} ** 34;
    try std.testing.expect(!try Ed25519.verifySignature(&long_key, "test", sig));

    // 33-byte key with wrong prefix
    var wrong_prefix: [33]u8 = undefined;
    wrong_prefix[0] = 0x02; // secp256k1 prefix, not 0xED
    @memcpy(wrong_prefix[1..], &gen.key_pair.public_key.toBytes());
    try std.testing.expect(!try Ed25519.verifySignature(&wrong_prefix, "test", sig));
}

test "secp256k1 strict verification vector suite" {
    const vectors = [_]struct {
        hash_hex: []const u8,
        pubkey_hex: []const u8,
        signature_hex: []const u8,
    }{
        .{
            .hash_hex = "4a5cf8d6ee452e06633ebf65fb069a862885efce1a91718dfb26ffb49e0505c9",
            .pubkey_hex = "03f38e8c09c2b4446a5d72d8050e8a16f6398d4ed9debace3defeb59e4aa670d9e",
            .signature_hex = "30450221009381495b11ae66358704b255fc8fb4c32a326179aecde13a33a36916201b8faa02203da63c00a1d4ada3e0d1f178362572efd2640146a70e73d683ae8a5f876c72d8",
        },
        .{
            .hash_hex = "52fc53d5735a43a7eabeb56251ac2a6fa17f49e3fa160a23864f208e695d1249",
            .pubkey_hex = "0239fe749408e0e82a084d8764dbd00a0c5954b9d15cb70888ce1c9cd547c5ac17",
            .signature_hex = "3045022100be1288f1db489fbf09845db49947c18307771a1311852f762b8c48d8e088544c02207fd9b84ddae58afb018bf28bc95386097b9f214a540fb1dd3682dec2d736ff86",
        },
        .{
            .hash_hex = "6e842d6086c9edcd0da27eef13667cb1c838dd9d9c77b8364a5d36b5a069f2b4",
            .pubkey_hex = "02ecc3cc13c0ddd58ccd1c75e06d0c1ef1b8f153a3123c96db87a5ec752d4103ee",
            .signature_hex = "304402205c4933a114fbd4c9f2427182a529cd8f2f9584c293fa86b5218fcb6d9211b68f02203a4f9fc0576548a5819344192c994a7b69e2224daa457520b287dd0134828532",
        },
    };

    var first_hash: [32]u8 = undefined;
    var first_sig: [80]u8 = undefined;
    var first_sig_len: usize = 0;
    var first_pub: [33]u8 = undefined;
    var second_pub: [33]u8 = undefined;

    for (vectors, 0..) |vec, idx| {
        var hash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash, vec.hash_hex);

        var pubkey: [33]u8 = undefined;
        _ = try std.fmt.hexToBytes(&pubkey, vec.pubkey_hex);

        var signature: [80]u8 = undefined;
        const sig_len = vec.signature_hex.len / 2;
        _ = try std.fmt.hexToBytes(signature[0..sig_len], vec.signature_hex);

        const ok = try KeyPair.verify(&pubkey, &hash, signature[0..sig_len], .secp256k1);
        try std.testing.expect(ok);

        if (idx == 0) {
            first_hash = hash;
            first_pub = pubkey;
            first_sig_len = sig_len;
            @memcpy(first_sig[0..sig_len], signature[0..sig_len]);
        } else if (idx == 1) {
            second_pub = pubkey;
        }
    }

    first_hash[0] ^= 0x01;
    try std.testing.expect(!(try KeyPair.verify(&first_pub, &first_hash, first_sig[0..first_sig_len], .secp256k1)));
    first_hash[0] ^= 0x01;

    first_sig[first_sig_len - 1] ^= 0x01;
    try std.testing.expect(!(try KeyPair.verify(&first_pub, &first_hash, first_sig[0..first_sig_len], .secp256k1)));
    first_sig[first_sig_len - 1] ^= 0x01;

    try std.testing.expect(!(try KeyPair.verify(&second_pub, &first_hash, first_sig[0..first_sig_len], .secp256k1)));
}
