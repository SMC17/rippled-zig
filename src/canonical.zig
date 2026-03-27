const std = @import("std");
const types = @import("types.zig");

/// XRPL Canonical Field Ordering and Serialization
///
/// XRPL binary serialization rules:
/// 1. Fields are identified by (type_code, field_code)
/// 2. Serialization order: sort by type_code first, then field_code
/// 3. Field header encoding:
///    - If type < 16 and field < 16: single byte = (type << 4) | field
///    - If type < 16 and field >= 16: two bytes = (type << 4) | 0, field
///    - If type >= 16 and field < 16: two bytes = field, type
///    - If type >= 16 and field >= 16: three bytes = 0, type, field
///
/// XRPL Type Codes:
///   1 = UInt16
///   2 = UInt32
///   3 = UInt64 (not used for Amount)
///   4 = Hash128
///   5 = Hash256
///   6 = Amount
///   7 = Blob (variable-length)
///   8 = AccountID
///  14 = STObject
///  15 = STArray
pub const TypeCode = struct {
    pub const UInt16: u8 = 1;
    pub const UInt32: u8 = 2;
    pub const UInt64: u8 = 3;
    pub const Hash128: u8 = 4;
    pub const Hash256: u8 = 5;
    pub const Amount: u8 = 6;
    pub const Blob: u8 = 7;
    pub const AccountID: u8 = 8;
    pub const STObject: u8 = 14;
    pub const STArray: u8 = 15;
};

pub const FieldOrder = struct {
    type_code: u8,
    field_code: u8,
    data: []const u8,

    pub fn lessThan(_: void, a: FieldOrder, b: FieldOrder) bool {
        if (a.type_code != b.type_code) {
            return a.type_code < b.type_code;
        }
        return a.field_code < b.field_code;
    }
};

/// Canonical serializer that sorts fields in XRPL-correct order
pub const CanonicalSerializer = struct {
    allocator: std.mem.Allocator,
    fields: std.ArrayList(FieldOrder),

    pub fn init(allocator: std.mem.Allocator) !CanonicalSerializer {
        return CanonicalSerializer{
            .allocator = allocator,
            .fields = try std.ArrayList(FieldOrder).initCapacity(allocator, 20),
        };
    }

    pub fn deinit(self: *CanonicalSerializer) void {
        for (self.fields.items) |field| {
            self.allocator.free(field.data);
        }
        self.fields.deinit();
    }

    /// Add a raw field with type and field codes
    pub fn addField(self: *CanonicalSerializer, type_code: u8, field_code: u8, data: []const u8) !void {
        const owned_data = try self.allocator.dupe(u8, data);
        try self.fields.append(FieldOrder{
            .type_code = type_code,
            .field_code = field_code,
            .data = owned_data,
        });
    }

    // ── Typed field helpers ──

    /// Add UInt16 field (type code 1)
    pub fn addUInt16(self: *CanonicalSerializer, field_code: u8, value: u16) !void {
        var data: [2]u8 = undefined;
        std.mem.writeInt(u16, &data, value, .big);
        try self.addField(TypeCode.UInt16, field_code, &data);
    }

    /// Add UInt32 field (type code 2)
    pub fn addUInt32(self: *CanonicalSerializer, field_code: u8, value: u32) !void {
        var data: [4]u8 = undefined;
        std.mem.writeInt(u32, &data, value, .big);
        try self.addField(TypeCode.UInt32, field_code, &data);
    }

    /// Add UInt64 field (type code 3)
    pub fn addUInt64(self: *CanonicalSerializer, field_code: u8, value: u64) !void {
        var data: [8]u8 = undefined;
        std.mem.writeInt(u64, &data, value, .big);
        try self.addField(TypeCode.UInt64, field_code, &data);
    }

    /// Add XRP Amount field (type code 6)
    /// XRP amounts: set bit 62 (positive), clear bit 63 (not IOU)
    /// Encoded as: 0x4000000000000000 | drops
    pub fn addXRPAmount(self: *CanonicalSerializer, field_code: u8, drops: u64) !void {
        var data: [8]u8 = undefined;
        const encoded = 0x4000000000000000 | drops;
        std.mem.writeInt(u64, &data, encoded, .big);
        try self.addField(TypeCode.Amount, field_code, &data);
    }

    /// Add Account ID field (type code 8)
    /// Account IDs are 20 bytes with VL prefix
    pub fn addAccountID(self: *CanonicalSerializer, field_code: u8, account: types.AccountID) !void {
        // AccountID fields use VL encoding: length prefix + 20 bytes
        var data: [21]u8 = undefined;
        data[0] = 20; // VL length prefix
        @memcpy(data[1..21], &account);
        try self.addField(TypeCode.AccountID, field_code, &data);
    }

    /// Add Hash256 field (type code 5)
    pub fn addHash256(self: *CanonicalSerializer, field_code: u8, hash: [32]u8) !void {
        try self.addField(TypeCode.Hash256, field_code, &hash);
    }

    /// Add Blob/VL field (type code 7) — variable-length with length prefix
    pub fn addBlob(self: *CanonicalSerializer, field_code: u8, data: []const u8) !void {
        var encoded = try std.ArrayList(u8).initCapacity(self.allocator, data.len + 3);
        defer encoded.deinit();

        // XRPL VL encoding
        if (data.len <= 192) {
            try encoded.append(@intCast(data.len));
        } else if (data.len <= 12480) {
            const len = data.len - 193;
            try encoded.append(193 + @as(u8, @intCast(len / 256)));
            try encoded.append(@intCast(len % 256));
        } else {
            const len = data.len - 12481;
            try encoded.append(241 + @as(u8, @intCast(len / 65536)));
            try encoded.append(@intCast((len / 256) % 256));
            try encoded.append(@intCast(len % 256));
        }
        try encoded.appendSlice(data);

        const final_data = try encoded.toOwnedSlice();
        // addField will dupe, but we already own this — transfer ownership directly
        try self.fields.append(FieldOrder{
            .type_code = TypeCode.Blob,
            .field_code = field_code,
            .data = final_data,
        });
    }

    // Legacy alias for backward compatibility with canonical_tx.zig
    pub fn addVL(self: *CanonicalSerializer, field_code: u8, data: []const u8) !void {
        return self.addBlob(field_code, data);
    }

    /// Encode a field header byte(s) for (type_code, field_code)
    fn encodeFieldHeader(output: *std.ArrayList(u8), type_code: u8, field_code: u8) !void {
        if (type_code < 16 and field_code < 16) {
            try output.append((type_code << 4) | field_code);
        } else if (type_code < 16 and field_code >= 16) {
            try output.append(type_code << 4);
            try output.append(field_code);
        } else if (type_code >= 16 and field_code < 16) {
            try output.append(field_code);
            try output.append(type_code);
        } else {
            try output.append(0);
            try output.append(type_code);
            try output.append(field_code);
        }
    }

    /// Finalize: Sort fields and output in canonical XRPL order
    pub fn finish(self: *CanonicalSerializer) ![]u8 {
        // Sort fields by (type_code, field_code) — XRPL canonical ordering
        std.mem.sort(FieldOrder, self.fields.items, {}, FieldOrder.lessThan);

        var output = try std.ArrayList(u8).initCapacity(self.allocator, self.fields.items.len * 16);
        errdefer output.deinit();

        for (self.fields.items) |field| {
            // Encode field header
            try encodeFieldHeader(&output, field.type_code, field.field_code);
            // Append field data
            try output.appendSlice(field.data);
        }

        return output.toOwnedSlice();
    }
};

// ── Tests ──

test "canonical ordering produces correct field sequence" {
    const allocator = std.testing.allocator;
    var ser = try CanonicalSerializer.init(allocator);
    defer ser.deinit();

    // Add fields out of order
    try ser.addUInt32(4, 1000); // Sequence (type 2, field 4)
    try ser.addXRPAmount(8, 10); // Fee (type 6, field 8)
    try ser.addUInt16(2, 0); // TransactionType (type 1, field 2)

    const result = try ser.finish();
    defer allocator.free(result);

    // Expected order: UInt16 (type 1) < UInt32 (type 2) < Amount (type 6)
    // First byte should be field header for (type=1, field=2) = 0x12
    try std.testing.expectEqual(@as(u8, 0x12), result[0]);
    // After UInt16 (2 bytes data), next should be (type=2, field=4) = 0x24
    try std.testing.expectEqual(@as(u8, 0x24), result[3]);
    // After UInt32 (4 bytes data), next should be (type=6, field=8) = 0x68
    try std.testing.expectEqual(@as(u8, 0x68), result[8]);

    std.debug.print("[PASS] Canonical field ordering with correct XRPL type codes\n", .{});
    std.debug.print("   Output length: {d} bytes\n", .{result.len});
}

test "field sorting by type then field code" {
    var fields = [_]FieldOrder{
        .{ .type_code = TypeCode.Amount, .field_code = 8, .data = &[_]u8{} },
        .{ .type_code = TypeCode.UInt32, .field_code = 4, .data = &[_]u8{} },
        .{ .type_code = TypeCode.UInt16, .field_code = 2, .data = &[_]u8{} },
        .{ .type_code = TypeCode.AccountID, .field_code = 1, .data = &[_]u8{} },
        .{ .type_code = TypeCode.UInt32, .field_code = 2, .data = &[_]u8{} }, // Flags
    };

    std.mem.sort(FieldOrder, &fields, {}, FieldOrder.lessThan);

    try std.testing.expectEqual(TypeCode.UInt16, fields[0].type_code);
    try std.testing.expectEqual(TypeCode.UInt32, fields[1].type_code);
    try std.testing.expectEqual(@as(u8, 2), fields[1].field_code); // Flags
    try std.testing.expectEqual(TypeCode.UInt32, fields[2].type_code);
    try std.testing.expectEqual(@as(u8, 4), fields[2].field_code); // Sequence
    try std.testing.expectEqual(TypeCode.Amount, fields[3].type_code);
    try std.testing.expectEqual(TypeCode.AccountID, fields[4].type_code);

    std.debug.print("[PASS] Field sorting works correctly\n", .{});
}

test "XRP amount encoding" {
    const allocator = std.testing.allocator;
    var ser = try CanonicalSerializer.init(allocator);
    defer ser.deinit();

    // 1 XRP = 1,000,000 drops
    try ser.addXRPAmount(1, 1_000_000);

    const result = try ser.finish();
    defer allocator.free(result);

    // Field header: type=6, field=1 → 0x61
    try std.testing.expectEqual(@as(u8, 0x61), result[0]);

    // Amount bytes: 0x4000000000000000 | 1000000 = 0x40000000000F4240
    try std.testing.expectEqual(@as(u8, 0x40), result[1]);
    try std.testing.expectEqual(@as(u8, 0x00), result[2]);
    try std.testing.expectEqual(@as(u8, 0x00), result[3]);
    try std.testing.expectEqual(@as(u8, 0x00), result[4]);
    try std.testing.expectEqual(@as(u8, 0x00), result[5]);
    try std.testing.expectEqual(@as(u8, 0x0F), result[6]);
    try std.testing.expectEqual(@as(u8, 0x42), result[7]);
    try std.testing.expectEqual(@as(u8, 0x40), result[8]);

    std.debug.print("[PASS] XRP amount encoding correct\n", .{});
}

test "field header encoding" {
    const allocator = std.testing.allocator;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 4);
    defer buf.deinit();

    // type < 16, field < 16 → single byte
    try CanonicalSerializer.encodeFieldHeader(&buf, 1, 2);
    try std.testing.expectEqual(@as(u8, 0x12), buf.items[0]);
    buf.clearRetainingCapacity();

    // type < 16, field >= 16 → two bytes
    try CanonicalSerializer.encodeFieldHeader(&buf, 2, 20);
    try std.testing.expectEqual(@as(u8, 0x20), buf.items[0]);
    try std.testing.expectEqual(@as(u8, 20), buf.items[1]);

    std.debug.print("[PASS] Field header encoding correct\n", .{});
}
