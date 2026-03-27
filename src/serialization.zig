const std = @import("std");
const types = @import("types.zig");

/// XRPL Canonical Serialization
///
/// XRP Ledger uses a specific binary format for transactions and ledger objects.
/// Fields must be serialized in canonical order with specific type prefixes.
///
/// Format: [Type:1byte][Field:1byte][Value]
///
/// This is CRITICAL for:
/// - Matching transaction hashes with real network
/// - Generating correct signatures
/// - Validating ledger state
pub const Serializer = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Serializer {
        return Serializer{
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 256),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Serializer) void {
        self.buffer.deinit();
    }

    /// Add a UInt8 field
    pub fn addUInt8(self: *Serializer, field: FieldID, value: u8) !void {
        const type_code: u8 = 0x10; // UInt8 type
        try self.buffer.append(type_code | @intFromEnum(field));
        try self.buffer.append(value);
    }

    /// Add a UInt16 field
    pub fn addUInt16(self: *Serializer, field: FieldID, value: u16) !void {
        const type_code: u8 = 0x10; // UInt16 type
        try self.buffer.append(type_code | @intFromEnum(field));
        try self.buffer.appendSlice(std.mem.asBytes(&std.mem.nativeToBig(u16, value)));
    }

    /// Add a UInt32 field
    pub fn addUInt32(self: *Serializer, field: FieldID, value: u32) !void {
        const type_code: u8 = 0x20; // UInt32 type
        try self.buffer.append(type_code | @intFromEnum(field));
        try self.buffer.appendSlice(std.mem.asBytes(&std.mem.nativeToBig(u32, value)));
    }

    /// Add a UInt64 field (Amount in drops)
    pub fn addAmount(self: *Serializer, field: FieldID, amount: types.Amount) !void {
        switch (amount) {
            .xrp => |drops| {
                // XRP amount: 64-bit with positive bit set
                const encoded = drops | (1 << 62); // Set "is positive" bit
                try self.addUInt64(field, encoded);
            },
            .iou => |iou| {
                // IOU amount: Different encoding
                // Bit 63: 0 = positive, 1 = negative
                // Bits 62-54: Exponent
                // Bits 53-0: Mantissa
                const sign_bit: u64 = if (iou.value >= 0) 0 else (1 << 63);
                const exp_bits: u64 = @as(u64, @intCast(iou.exponent + 97)) << 54;
                const mantissa_bits: u64 = @abs(iou.value);
                const encoded = sign_bit | exp_bits | mantissa_bits | (1 << 62); // Set "not XRP" bit

                try self.addUInt64(field, encoded);
                try self.addAccountID(.{ .issuer = 0 }, iou.issuer); // Add issuer
            },
        }
    }

    /// Add a UInt64 field
    fn addUInt64(self: *Serializer, field: FieldID, value: u64) !void {
        const type_code: u8 = 0x60; // UInt64 type
        try self.buffer.append(type_code | @intFromEnum(field));
        try self.buffer.appendSlice(std.mem.asBytes(&std.mem.nativeToBig(u64, value)));
    }

    /// Add an Account ID (160-bit)
    pub fn addAccountID(self: *Serializer, field: FieldID, account: types.AccountID) !void {
        const type_code: u8 = 0x80; // AccountID type
        try self.buffer.append(type_code | @intFromEnum(field));
        try self.buffer.appendSlice(&account);
    }

    /// Add a Hash256 field
    pub fn addHash256(self: *Serializer, field: FieldID, hash: [32]u8) !void {
        const type_code: u8 = 0x50; // Hash256 type
        try self.buffer.append(type_code | @intFromEnum(field));
        try self.buffer.appendSlice(&hash);
    }

    /// Add a variable length field
    pub fn addVL(self: *Serializer, field: FieldID, data: []const u8) !void {
        const type_code: u8 = 0x70; // VL (variable length) type
        try self.buffer.append(type_code | @intFromEnum(field));

        // Encode length
        if (data.len <= 192) {
            try self.buffer.append(@intCast(data.len));
        } else if (data.len <= 12480) {
            const len = data.len - 193;
            try self.buffer.append(193 + @as(u8, @intCast(len / 256)));
            try self.buffer.append(@intCast(len % 256));
        } else {
            const len = data.len - 12481;
            try self.buffer.append(241 + @as(u8, @intCast(len / 65536)));
            try self.buffer.append(@intCast((len / 256) % 256));
            try self.buffer.append(@intCast(len % 256));
        }

        try self.buffer.appendSlice(data);
    }

    /// Get the serialized bytes
    pub fn finish(self: *Serializer) []const u8 {
        return self.buffer.items;
    }

    /// Get owned slice
    pub fn toOwnedSlice(self: *Serializer) ![]u8 {
        return self.buffer.toOwnedSlice();
    }
};

/// XRPL Field IDs (simplified - in production would be per-type)
pub const FieldID = enum(u8) {
    // Common fields
    account = 1,
    destination = 2,
    sequence = 3,
    fee = 4,
    amount = 5,
    signing_pub_key = 6,
    txn_signature = 7,
    flags = 8,
    issuer = 9,
    transaction_type = 10,

    _,
};

/// Deserializer for binary XRPL format
pub const Deserializer = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Deserializer {
        return Deserializer{
            .data = data,
            .pos = 0,
        };
    }

    /// Read a UInt8 field
    pub fn readUInt8(self: *Deserializer) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEnd;
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }

    /// Read a UInt32 field
    pub fn readUInt32(self: *Deserializer) !u32 {
        if (self.pos + 4 > self.data.len) return error.UnexpectedEnd;
        const bytes = self.data[self.pos .. self.pos + 4];
        self.pos += 4;
        return std.mem.readInt(u32, bytes[0..4], .big);
    }

    /// Read a UInt64 field
    pub fn readUInt64(self: *Deserializer) !u64 {
        if (self.pos + 8 > self.data.len) return error.UnexpectedEnd;
        const bytes = self.data[self.pos .. self.pos + 8];
        self.pos += 8;
        return std.mem.readInt(u64, bytes[0..8], .big);
    }

    /// Read an Account ID
    pub fn readAccountID(self: *Deserializer) !types.AccountID {
        if (self.pos + 20 > self.data.len) return error.UnexpectedEnd;
        var account: types.AccountID = undefined;
        @memcpy(&account, self.data[self.pos .. self.pos + 20]);
        self.pos += 20;
        return account;
    }

    /// Read variable length field
    pub fn readVL(self: *Deserializer, allocator: std.mem.Allocator) ![]u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEnd;

        const first_byte = self.data[self.pos];
        self.pos += 1;

        const len: usize = if (first_byte <= 192) blk: {
            break :blk first_byte;
        } else if (first_byte <= 240) blk: {
            if (self.pos >= self.data.len) return error.UnexpectedEnd;
            const second_byte = self.data[self.pos];
            self.pos += 1;
            break :blk 193 + ((first_byte - 193) * 256) + second_byte;
        } else blk: {
            if (self.pos + 2 > self.data.len) return error.UnexpectedEnd;
            const second_byte = self.data[self.pos];
            const third_byte = self.data[self.pos + 1];
            self.pos += 2;
            break :blk 12481 + ((first_byte - 241) * 65536) + (second_byte * 256) + third_byte;
        };

        if (self.pos + len > self.data.len) return error.UnexpectedEnd;
        const result = try allocator.dupe(u8, self.data[self.pos .. self.pos + len]);
        self.pos += len;
        return result;
    }
};

test "serializer initialization" {
    const allocator = std.testing.allocator;
    var ser = try Serializer.init(allocator);
    defer ser.deinit();

    try std.testing.expectEqual(@as(usize, 0), ser.buffer.items.len);
}

test "serialize uint32" {
    const allocator = std.testing.allocator;
    var ser = try Serializer.init(allocator);
    defer ser.deinit();

    try ser.addUInt32(.sequence, 12345);
    const result = ser.finish();

    // Should have type+field byte, then 4 bytes for value
    try std.testing.expectEqual(@as(usize, 5), result.len);
}

test "serialize account ID" {
    const allocator = std.testing.allocator;
    var ser = try Serializer.init(allocator);
    defer ser.deinit();

    const account = [_]u8{1} ** 20;
    try ser.addAccountID(.account, account);
    const result = ser.finish();

    // Should have type+field byte, then 20 bytes for account
    try std.testing.expectEqual(@as(usize, 21), result.len);
}

test "deserializer uint32" {
    const data = [_]u8{ 0x24, 0x00, 0x00, 0x30, 0x39 }; // Sequence = 12345
    var deser = Deserializer.init(&data);

    _ = try deser.readUInt8(); // Skip type byte
    const value = try deser.readUInt32();
    try std.testing.expectEqual(@as(u32, 12345), value);
}

test "variable length encoding" {
    const allocator = std.testing.allocator;
    var ser = try Serializer.init(allocator);
    defer ser.deinit();

    // Short string (< 192 bytes)
    try ser.addVL(.signing_pub_key, "test");

    // Should encode length as single byte
    const result = ser.finish();
    try std.testing.expect(result.len == 1 + 1 + 4); // type + len + data
}
