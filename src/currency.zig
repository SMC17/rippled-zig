const std = @import("std");

/// XRPL Currency Code — 160-bit (20-byte) representation.
///
/// Standard 3-character codes (e.g., "USD", "EUR"):
///   - Bytes 0-11: zero
///   - Bytes 12-14: ASCII characters (uppercase only)
///   - Bytes 15-19: zero
///   - First byte must NOT be 0x00 after encoding (but it is 0x00, so this
///     is distinguished from hex currencies by checking byte 0)
///
/// Hex/non-standard currencies:
///   - 20 arbitrary bytes (first byte != 0x00)
///
/// XRP is the native currency and has a special zero representation:
///   - All 20 bytes are zero
pub const CurrencyCode = struct {
    bytes: [20]u8,

    pub const XRP = CurrencyCode{ .bytes = [_]u8{0} ** 20 };

    /// Create a standard 3-character currency code
    pub fn fromStandard(code: []const u8) !CurrencyCode {
        if (code.len != 3) return error.InvalidCurrencyCode;

        // Validate: must be uppercase ASCII, not "XRP" (XRP is native)
        for (code) |c| {
            if (c < 0x20 or c > 0x7E) return error.InvalidCurrencyCode;
        }

        // "XRP" as issued currency is not valid
        if (std.mem.eql(u8, code, "XRP")) return error.InvalidCurrencyCode;

        var bytes = [_]u8{0} ** 20;
        bytes[12] = code[0];
        bytes[13] = code[1];
        bytes[14] = code[2];
        return CurrencyCode{ .bytes = bytes };
    }

    /// Create from 40-character hex string (non-standard currency)
    pub fn fromHex(hex: []const u8) !CurrencyCode {
        if (hex.len != 40) return error.InvalidCurrencyCode;

        var bytes: [20]u8 = undefined;
        for (0..20) |i| {
            bytes[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch {
                return error.InvalidCurrencyCode;
            };
        }

        // First byte must not be 0x00 for hex currencies
        if (bytes[0] == 0x00) return error.InvalidCurrencyCode;

        return CurrencyCode{ .bytes = bytes };
    }

    /// Check if this is XRP (native currency)
    pub fn isXRP(self: CurrencyCode) bool {
        return std.mem.eql(u8, &self.bytes, &CurrencyCode.XRP.bytes);
    }

    /// Check if this is a standard 3-char currency
    pub fn isStandard(self: CurrencyCode) bool {
        if (self.isXRP()) return false;
        if (self.bytes[0] != 0) return false; // hex currency
        // Check bytes 0-11 and 15-19 are zero
        for (self.bytes[0..12]) |b| {
            if (b != 0) return false;
        }
        for (self.bytes[15..20]) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    /// Get the 3-character code (only valid for standard currencies)
    pub fn toStandard(self: CurrencyCode) ![3]u8 {
        if (!self.isStandard()) return error.NotStandardCurrency;
        return [3]u8{ self.bytes[12], self.bytes[13], self.bytes[14] };
    }

    /// Format as string: "XRP", "USD", or hex
    pub fn toString(self: CurrencyCode, buf: []u8) ![]const u8 {
        if (self.isXRP()) {
            return std.fmt.bufPrint(buf, "XRP", .{});
        }
        if (self.isStandard()) {
            const code = try self.toStandard();
            return std.fmt.bufPrint(buf, "{s}", .{&code});
        }
        // Hex currency
        return std.fmt.bufPrint(buf, "{s}", .{std.fmt.fmtSliceHexLower(&self.bytes)});
    }
};

// ── Tests ──

test "XRP currency code" {
    const xrp = CurrencyCode.XRP;
    try std.testing.expect(xrp.isXRP());
    try std.testing.expect(!xrp.isStandard());

    var buf: [64]u8 = undefined;
    const formatted = try xrp.toString(&buf);
    try std.testing.expectEqualStrings("XRP", formatted);
    std.debug.print("[PASS] XRP currency code\n", .{});
}

test "standard 3-char currency code" {
    const usd = try CurrencyCode.fromStandard("USD");
    try std.testing.expect(!usd.isXRP());
    try std.testing.expect(usd.isStandard());
    const code = try usd.toStandard();
    try std.testing.expectEqualStrings("USD", &code);

    // Verify byte layout
    try std.testing.expectEqual(@as(u8, 0), usd.bytes[0]);
    try std.testing.expectEqual(@as(u8, 'U'), usd.bytes[12]);
    try std.testing.expectEqual(@as(u8, 'S'), usd.bytes[13]);
    try std.testing.expectEqual(@as(u8, 'D'), usd.bytes[14]);
    try std.testing.expectEqual(@as(u8, 0), usd.bytes[15]);

    std.debug.print("[PASS] Standard currency code (USD)\n", .{});
}

test "XRP as issued currency is invalid" {
    const result = CurrencyCode.fromStandard("XRP");
    try std.testing.expectError(error.InvalidCurrencyCode, result);
    std.debug.print("[PASS] XRP as issued currency rejected\n", .{});
}

test "hex currency code" {
    // Non-standard currency with first byte != 0
    const hex = try CurrencyCode.fromHex("0158415500000000C1F76FF6ECB0BAC600000000");
    try std.testing.expect(!hex.isXRP());
    try std.testing.expect(!hex.isStandard());
    try std.testing.expectEqual(@as(u8, 0x01), hex.bytes[0]);
    std.debug.print("[PASS] Hex currency code\n", .{});
}

test "invalid currency codes" {
    try std.testing.expectError(error.InvalidCurrencyCode, CurrencyCode.fromStandard("US"));
    try std.testing.expectError(error.InvalidCurrencyCode, CurrencyCode.fromStandard("USDT"));
    try std.testing.expectError(error.InvalidCurrencyCode, CurrencyCode.fromHex("00"));
    std.debug.print("[PASS] Invalid currency codes rejected\n", .{});
}
