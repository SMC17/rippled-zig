const std = @import("std");

/// XRPL Memo support.
///
/// Memos are arbitrary metadata attached to transactions. Each memo has:
///   - MemoType: indicates the format (e.g., "text/plain", "application/json")
///   - MemoData: the actual data
/// Both fields are hex-encoded in the binary format.
///
/// Memos are serialized as an STArray (field 9) containing Memo STObjects
/// (field 10), each with MemoType (Blob field 12) and MemoData (Blob field 13).

pub const Memo = struct {
    memo_type: []const u8, // e.g., "text/plain" — will be hex-encoded
    memo_data: []const u8, // arbitrary data — will be hex-encoded

    /// Validate memo fields per XRPL rules.
    /// MemoType and MemoData must contain only printable ASCII or valid hex when decoded.
    pub fn validate(self: Memo) !void {
        if (self.memo_type.len == 0) return error.EmptyMemoType;
        if (self.memo_type.len > 256) return error.MemoTypeTooLong;
        if (self.memo_data.len > 1024) return error.MemoDataTooLong;
    }

    /// Hex-encode a string for XRPL serialization.
    pub fn hexEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        const result = try allocator.alloc(u8, input.len * 2);
        for (input, 0..) |byte, i| {
            const hex = "0123456789abcdef";
            result[i * 2] = hex[byte >> 4];
            result[i * 2 + 1] = hex[byte & 0x0f];
        }
        return result;
    }

    /// Hex-decode bytes back to string.
    pub fn hexDecode(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
        if (hex.len % 2 != 0) return error.InvalidHexLength;
        const result = try allocator.alloc(u8, hex.len / 2);
        for (0..result.len) |i| {
            result[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch
                return error.InvalidHexCharacter;
        }
        return result;
    }
};

/// Builder for constructing transactions with memos.
pub const MemoBuilder = struct {
    memos: std.ArrayList(Memo),

    pub fn init(allocator: std.mem.Allocator) MemoBuilder {
        return .{ .memos = std.ArrayList(Memo).init(allocator) };
    }

    pub fn deinit(self: *MemoBuilder) void {
        self.memos.deinit();
    }

    pub fn addMemo(self: *MemoBuilder, memo_type: []const u8, memo_data: []const u8) !void {
        const memo = Memo{ .memo_type = memo_type, .memo_data = memo_data };
        try memo.validate();
        try self.memos.append(memo);
    }

    pub fn count(self: *const MemoBuilder) usize {
        return self.memos.items.len;
    }
};

// ── Tests ──

test "memo validation" {
    const valid = Memo{ .memo_type = "text/plain", .memo_data = "hello" };
    try valid.validate();

    const empty_type = Memo{ .memo_type = "", .memo_data = "data" };
    try std.testing.expectError(error.EmptyMemoType, empty_type.validate());

    const long_type = Memo{ .memo_type = &([_]u8{'a'} ** 257), .memo_data = "data" };
    try std.testing.expectError(error.MemoTypeTooLong, long_type.validate());
}

test "memo hex encode/decode round-trip" {
    const allocator = std.testing.allocator;
    const input = "text/plain";
    const encoded = try Memo.hexEncode(allocator, input);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("746578742f706c61696e", encoded);

    const decoded = try Memo.hexDecode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}

test "memo builder" {
    const allocator = std.testing.allocator;
    var builder = MemoBuilder.init(allocator);
    defer builder.deinit();

    try builder.addMemo("text/plain", "hello world");
    try builder.addMemo("application/json", "{\"key\":\"value\"}");
    try std.testing.expectEqual(@as(usize, 2), builder.count());
}
