const std = @import("std");
const types = @import("types.zig");

/// Cryptographic hash functions used in XRP Ledger
pub const Hash = struct {
    /// SHA-512 Half (first 256 bits of SHA-512)
    /// This is the primary hash function used in XRPL
    pub fn sha512Half(data: []const u8) [32]u8 {
        var full_hash: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(data, &full_hash, .{});

        var result: [32]u8 = undefined;
        @memcpy(&result, full_hash[0..32]);
        return result;
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

    /// Generate a new Ed25519 key pair
    pub fn generateEd25519(allocator: std.mem.Allocator) !KeyPair {
        // Generate key pair - uses std.crypto.random internally
        const key_pair = std.crypto.sign.Ed25519.KeyPair.generate();

        // Convert PublicKey and SecretKey structs to byte slices
        const pub_key_bytes = key_pair.public_key.toBytes();
        const public_key = try allocator.dupe(u8, &pub_key_bytes);
        const secret_key_bytes = key_pair.secret_key.toBytes();
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

                // XRPL secp256k1: sign SHA512Half(0x53 0x54 0x58 0x00 || data)
                const stx: [4]u8 = .{ 0x53, 0x54, 0x58, 0x00 };
                var msg_hash: [32]u8 = undefined;
                if (data.len == 32) {
                    @memcpy(&msg_hash, data);
                } else {
                    var buf = try allocator.alloc(u8, 4 + data.len);
                    defer allocator.free(buf);
                    @memcpy(buf[0..4], &stx);
                    @memcpy(buf[4..], data);
                    msg_hash = Hash.sha512Half(buf);
                }

                const secp = @import("secp256k1_binding.zig");
                return secp.signMessage(seckey, msg_hash, allocator);
            },
        }
    }

    /// Verify a signature
    pub fn verify(public_key: []const u8, data: []const u8, signature: []const u8, algorithm: SignatureAlgorithm) !bool {
        switch (algorithm) {
            .ed25519 => {
                if (public_key.len != 32 or signature.len != 64) {
                    return false;
                }

                var pub_key: [32]u8 = undefined;
                @memcpy(&pub_key, public_key);

                var sig_bytes: [64]u8 = undefined;
                @memcpy(&sig_bytes, signature);

                const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
                const pub_key_struct = try std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_key);

                // Verify signature using Signature.verify method (Zig 0.15.1 API)
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

                // Verify signature
                return secp.verifySignature(public_key, data, signature) catch false;
            },
        }
    }

    /// Get the account ID for this key pair
    pub fn getAccountID(self: KeyPair) types.AccountID {
        return Hash.accountID(self.public_key);
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
