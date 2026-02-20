const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");

/// Base58Check encoding for XRP Ledger addresses
///
/// XRPL addresses use Base58Check encoding:
/// 1. Version byte prefix
/// 2. Payload (account ID)
/// 3. 4-byte checksum (SHA-256 double hash)
///
/// This is CRITICAL for user-facing addresses like "rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T"
pub const Base58 = struct {
    const alphabet = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz";

    /// Encode bytes to Base58 string
    pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        if (data.len == 0) return try allocator.dupe(u8, "");

        // Count leading zeros
        var zeros: usize = 0;
        for (data) |byte| {
            if (byte != 0) break;
            zeros += 1;
        }

        // Allocate worst-case size
        var result = try std.ArrayList(u8).initCapacity(allocator, data.len * 2);
        errdefer result.deinit(allocator);

        // Convert to base58
        var num = try std.ArrayList(u8).initCapacity(allocator, data.len);
        defer num.deinit(allocator);
        // Skip leading zeros for conversion math; they are re-added as alphabet[0] prefix.
        try num.appendSlice(allocator, data[zeros..]);

        while (num.items.len > 0 and num.items[0] != 0) {
            var carry: u32 = 0;
            for (num.items) |*byte| {
                carry = carry * 256 + byte.*;
                byte.* = @intCast(carry / 58);
                carry = carry % 58;
            }

            try result.append(allocator, alphabet[carry]);

            // Remove leading zeros from num
            while (num.items.len > 0 and num.items[0] == 0) {
                _ = num.orderedRemove(0);
            }
        }

        // Add leading '1's for leading zero bytes
        for (0..zeros) |_| {
            try result.append(allocator, alphabet[0]);
        }

        // Reverse the result
        std.mem.reverse(u8, result.items);

        return result.toOwnedSlice(allocator);
    }

    /// Decode Base58 string to bytes
    pub fn decode(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
        if (str.len == 0) return try allocator.dupe(u8, &[_]u8{});

        // Count leading '1's
        var zeros: usize = 0;
        // Skip leading zero characters for conversion math; they are re-added as 0x00 bytes.
        for (str[zeros..]) |char| {
            if (char != alphabet[0]) break;
            zeros += 1;
        }

        // Decode
        var result = try std.ArrayList(u8).initCapacity(allocator, str.len);
        errdefer result.deinit(allocator);

        for (str) |char| {
            // Find character in alphabet
            const value = for (alphabet, 0..) |c, i| {
                if (c == char) break i;
            } else return error.InvalidBase58Character;

            // Multiply result by 58 and add value
            var carry: u32 = @intCast(value);
            for (result.items) |*byte| {
                carry += @as(u32, byte.*) * 58;
                byte.* = @intCast(carry % 256);
                carry /= 256;
            }

            while (carry > 0) {
                try result.append(allocator, @intCast(carry % 256));
                carry /= 256;
            }
        }

        // Add leading zeros
        for (0..zeros) |_| {
            try result.append(allocator, 0);
        }

        // Reverse
        std.mem.reverse(u8, result.items);

        return result.toOwnedSlice(allocator);
    }

    /// Encode account ID to XRPL address format
    pub fn encodeAccountID(allocator: std.mem.Allocator, account_id: types.AccountID) ![]u8 {
        // Version byte for account (0x00)
        var data: [25]u8 = undefined;
        data[0] = 0x00;
        @memcpy(data[1..21], &account_id);

        // Calculate checksum (SHA-256 twice, take first 4 bytes)
        var hash1: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data[0..21], &hash1, .{});

        var hash2: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&hash1, &hash2, .{});

        @memcpy(data[21..25], hash2[0..4]);

        // Base58 encode
        return try encode(allocator, &data);
    }

    /// Decode XRPL address to account ID
    pub fn decodeAccountID(allocator: std.mem.Allocator, address: []const u8) !types.AccountID {
        const decoded = try decode(allocator, address);
        defer allocator.free(decoded);

        if (decoded.len != 25) return error.InvalidAddress;
        if (decoded[0] != 0x00) return error.InvalidAddressVersion;

        // Verify checksum
        var hash1: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(decoded[0..21], &hash1, .{});

        var hash2: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&hash1, &hash2, .{});

        if (!std.mem.eql(u8, decoded[21..25], hash2[0..4])) {
            return error.InvalidChecksum;
        }

        var account_id: types.AccountID = undefined;
        @memcpy(&account_id, decoded[1..21]);
        return account_id;
    }
};

test "base58 encode decode" {
    const allocator = std.testing.allocator;

    const original = "Hello World!";
    const encoded = try Base58.encode(allocator, original);
    defer allocator.free(encoded);

    const decoded = try Base58.decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "account ID encoding" {
    const allocator = std.testing.allocator;

    const account_id = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13,
    };

    const address = try Base58.encodeAccountID(allocator, account_id);
    defer allocator.free(address);

    // Should start with 'r' (version 0x00 encodes to 'r' prefix)
    try std.testing.expect(address[0] == 'r');

    // Round-trip test
    const decoded = try Base58.decodeAccountID(allocator, address);
    try std.testing.expectEqualSlices(u8, &account_id, &decoded);
}

test "invalid address rejection" {
    const allocator = std.testing.allocator;

    // Invalid checksum
    try std.testing.expectError(error.InvalidBase58Character, Base58.decodeAccountID(allocator, "invalid!"));
}
