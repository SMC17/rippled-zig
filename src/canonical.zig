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

    /// Add IOU (token) Amount field (type code 6, 48 bytes total).
    ///
    /// Encoding (48 bytes):
    ///   Bytes 0-7:  numeric amount
    ///     Bit 63 = 1 (not XRP / is token)
    ///     Bit 62 = 1 if positive, 0 if negative
    ///     Bits 54-61 (8 bits): biased exponent = actual_exponent + 97
    ///     Bits 0-53 (54 bits): mantissa (normalized to [10^15, 10^16-1])
    ///     Special zero encoding: 0x80_00_00_00_00_00_00_00
    ///   Bytes 8-27:  160-bit currency code
    ///   Bytes 28-47: 20-byte issuer AccountID (raw, no VL prefix)
    pub fn addIOUAmount(
        self: *CanonicalSerializer,
        field_code: u8,
        amount: types.IOUAmount,
    ) !void {
        var data: [48]u8 = undefined;

        // -- Numeric amount (8 bytes) --
        if (amount.mantissa == 0) {
            // Canonical zero
            std.mem.writeInt(u64, data[0..8], 0x80_00_00_00_00_00_00_00, .big);
        } else {
            // Normalize mantissa into [10^15, 10^16-1]
            var mantissa: u64 = amount.mantissa;
            var exponent: i16 = @as(i16, amount.exponent);

            // Scale up if mantissa < 10^15
            while (mantissa < 1_000_000_000_000_000 and exponent > -96) {
                mantissa *= 10;
                exponent -= 1;
            }
            // Scale down if mantissa >= 10^16
            while (mantissa >= 10_000_000_000_000_000 and exponent < 80) {
                mantissa /= 10;
                exponent += 1;
            }

            const biased_exp: u64 = @intCast(exponent + 97);
            var encoded: u64 = 0;
            encoded |= @as(u64, 1) << 63; // bit 63: not XRP
            if (!amount.is_negative) {
                encoded |= @as(u64, 1) << 62; // bit 62: positive
            }
            encoded |= (biased_exp & 0xFF) << 54; // bits 54-61: exponent
            encoded |= mantissa & 0x003F_FFFF_FFFF_FFFF; // bits 0-53: mantissa

            std.mem.writeInt(u64, data[0..8], encoded, .big);
        }

        // -- Currency code (20 bytes) --
        @memcpy(data[8..28], &amount.currency.bytes);

        // -- Issuer AccountID (20 bytes, raw, no VL prefix) --
        @memcpy(data[28..48], &amount.issuer);

        try self.addField(TypeCode.Amount, field_code, &data);
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

test "IOU amount zero encoding" {
    const allocator = std.testing.allocator;
    var ser = try CanonicalSerializer.init(allocator);
    defer ser.deinit();

    const usd = try types.CurrencyCode.fromStandard("USD");
    const issuer = [_]u8{0} ** 20;
    const amt = types.IOUAmount.zero(usd, issuer);

    try ser.addIOUAmount(1, amt);
    const result = try ser.finish();
    defer allocator.free(result);

    // Field header: type=6, field=1 → 0x61
    try std.testing.expectEqual(@as(u8, 0x61), result[0]);
    // IOU zero = 0x8000000000000000
    try std.testing.expectEqual(@as(u8, 0x80), result[1]);
    for (2..9) |i| {
        try std.testing.expectEqual(@as(u8, 0x00), result[i]);
    }
    // Total: 1 (header) + 48 (data) = 49 bytes
    try std.testing.expectEqual(@as(usize, 49), result.len);

    std.debug.print("[PASS] IOU zero amount encoding\n", .{});
}

test "IOU amount positive encoding" {
    // Encode 1.5 USD = mantissa 15, exponent -1
    // Normalized: mantissa 1_500_000_000_000_000, exponent -15
    // But since we pass pre-normalized: mantissa 15, exp -1
    // Normalization: 15 < 10^15, so multiply up:
    //   15 * 10^14 = 1_500_000_000_000_000, exponent = -1 - 14 = -15
    // biased_exp = -15 + 97 = 82 = 0x52
    // encoded = (1<<63) | (1<<62) | (82<<54) | 1_500_000_000_000_000
    //         = 0x8000000000000000 | 0x4000000000000000 | (0x52 << 54) | 0x0005_5434_2716_4000
    // Let's compute: 0x52 << 54 = 0x1480_0000_0000_0000
    // result = 0xC000000000000000 | 0x1480_0000_0000_0000 | 0x0005_5434_2716_4000
    //        = 0xD485_5434_2716_4000
    const allocator = std.testing.allocator;
    var ser = try CanonicalSerializer.init(allocator);
    defer ser.deinit();

    const usd = try types.CurrencyCode.fromStandard("USD");
    const issuer = [_]u8{0xAA} ** 20;
    const amt = types.IOUAmount{
        .mantissa = 15,
        .exponent = -1,
        .is_negative = false,
        .currency = usd,
        .issuer = issuer,
    };

    try ser.addIOUAmount(1, amt);
    const result = try ser.finish();
    defer allocator.free(result);

    // Extract the 8-byte numeric amount (skip 1-byte field header)
    const numeric = std.mem.readInt(u64, result[1..9], .big);

    // Verify bit 63 set (not XRP)
    try std.testing.expect(numeric & (@as(u64, 1) << 63) != 0);
    // Verify bit 62 set (positive)
    try std.testing.expect(numeric & (@as(u64, 1) << 62) != 0);

    // Verify expected value: 0xD485_543D_F729_C000
    // mantissa 1_500_000_000_000_000, biased_exp 82 (0x52)
    try std.testing.expectEqual(@as(u64, 0xD485_543D_F729_C000), numeric);

    // Verify currency code at bytes 9-28 (offsets in result)
    try std.testing.expectEqual(@as(u8, 0), result[9]); // first byte of currency
    try std.testing.expectEqual(@as(u8, 'U'), result[9 + 12]);
    try std.testing.expectEqual(@as(u8, 'S'), result[9 + 13]);
    try std.testing.expectEqual(@as(u8, 'D'), result[9 + 14]);

    // Verify issuer at bytes 29-48
    try std.testing.expectEqual(@as(u8, 0xAA), result[29]);
    try std.testing.expectEqual(@as(u8, 0xAA), result[48]);

    std.debug.print("[PASS] IOU positive amount encoding (1.5 USD)\n", .{});
}

test "IOU amount negative encoding" {
    const allocator = std.testing.allocator;
    var ser = try CanonicalSerializer.init(allocator);
    defer ser.deinit();

    const usd = try types.CurrencyCode.fromStandard("USD");
    const issuer = [_]u8{0xBB} ** 20;

    // -1.0 USD: mantissa=1, exponent=0
    // Normalized: mantissa=1_000_000_000_000_000, exponent=-15
    // biased_exp = -15 + 97 = 82 = 0x52
    // encoded = (1<<63) | (0<<62) | (82<<54) | 1_000_000_000_000_000
    //         = 0x8000000000000000 | 0x1480_0000_0000_0000 | 0x0003_8D7E_A4C6_8000
    //         = 0x9483_8D7E_A4C6_8000
    const amt = types.IOUAmount{
        .mantissa = 1,
        .exponent = 0,
        .is_negative = true,
        .currency = usd,
        .issuer = issuer,
    };

    try ser.addIOUAmount(1, amt);
    const result = try ser.finish();
    defer allocator.free(result);

    const numeric = std.mem.readInt(u64, result[1..9], .big);

    // bit 63 set (not XRP)
    try std.testing.expect(numeric & (@as(u64, 1) << 63) != 0);
    // bit 62 clear (negative)
    try std.testing.expect(numeric & (@as(u64, 1) << 62) == 0);

    try std.testing.expectEqual(@as(u64, 0x9483_8D7E_A4C6_8000), numeric);

    std.debug.print("[PASS] IOU negative amount encoding (-1.0 USD)\n", .{});
}

test "IOU amount with hex currency code" {
    const allocator = std.testing.allocator;
    var ser = try CanonicalSerializer.init(allocator);
    defer ser.deinit();

    const hex_currency = try types.CurrencyCode.fromHex("015841551A748AD2C1F76FF6ECB0CCCD00000000");
    const issuer = [_]u8{0xCC} ** 20;
    const amt = types.IOUAmount{
        .mantissa = 1_000_000_000_000_000,
        .exponent = -15,
        .is_negative = false,
        .currency = hex_currency,
        .issuer = issuer,
    };

    try ser.addIOUAmount(1, amt);
    const result = try ser.finish();
    defer allocator.free(result);

    // Verify currency code bytes start at offset 9
    try std.testing.expectEqual(@as(u8, 0x01), result[9]);
    try std.testing.expectEqual(@as(u8, 0x58), result[10]);

    // Total length: 1 header + 48 data = 49
    try std.testing.expectEqual(@as(usize, 49), result.len);

    std.debug.print("[PASS] IOU amount with hex currency code\n", .{});
}

test "IOU amount 48-byte output size" {
    // Verify the IOU amount data (excluding field header) is exactly 48 bytes
    const allocator = std.testing.allocator;
    var ser = try CanonicalSerializer.init(allocator);
    defer ser.deinit();

    const eur = try types.CurrencyCode.fromStandard("EUR");
    const issuer = [_]u8{0x11} ** 20;
    const amt = types.IOUAmount{
        .mantissa = 100,
        .exponent = 0,
        .is_negative = false,
        .currency = eur,
        .issuer = issuer,
    };

    try ser.addIOUAmount(1, amt);

    // Check the stored field data is exactly 48 bytes
    try std.testing.expectEqual(@as(usize, 48), ser.fields.items[0].data.len);

    const result = try ser.finish();
    defer allocator.free(result);

    std.debug.print("[PASS] IOU amount produces 48-byte data payload\n", .{});
}

// ── Deserializer ──

/// Parsed field from binary deserialization
pub const ParsedField = struct {
    type_code: u8,
    field_code: u8,
    data: []const u8,
};

/// XRPL Canonical Deserializer — parses binary format back to TransactionJSON
///
/// Inverse of CanonicalSerializer. Decodes the field-header + data pairs
/// emitted by the serializer, reconstructing a TransactionJSON struct.
pub const CanonicalDeserializer = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) CanonicalDeserializer {
        return CanonicalDeserializer{
            .data = data,
            .pos = 0,
            .allocator = allocator,
        };
    }

    /// Parse a 1-3 byte field header, returning (type_code, field_code).
    ///
    /// Encoding rules (inverse of CanonicalSerializer.encodeFieldHeader):
    ///   - high nibble != 0 and low nibble != 0: type = high, field = low  (1 byte)
    ///   - high nibble != 0 and low nibble == 0: type = high, field = next (2 bytes)
    ///   - high nibble == 0 and low nibble != 0: field = low, type = next  (2 bytes)
    ///   - both nibbles 0: type = next byte, field = byte after            (3 bytes)
    pub fn parseFieldHeader(self: *CanonicalDeserializer) !struct { type_code: u8, field_code: u8 } {
        if (self.pos >= self.data.len) return error.UnexpectedEnd;
        const byte = self.data[self.pos];
        self.pos += 1;

        const high: u8 = byte >> 4;
        const low: u8 = byte & 0x0F;

        if (high != 0 and low != 0) {
            return .{ .type_code = high, .field_code = low };
        } else if (high != 0 and low == 0) {
            if (self.pos >= self.data.len) return error.UnexpectedEnd;
            const field_code = self.data[self.pos];
            self.pos += 1;
            return .{ .type_code = high, .field_code = field_code };
        } else if (high == 0 and low != 0) {
            if (self.pos >= self.data.len) return error.UnexpectedEnd;
            const type_code = self.data[self.pos];
            self.pos += 1;
            return .{ .type_code = type_code, .field_code = low };
        } else {
            if (self.pos + 2 > self.data.len) return error.UnexpectedEnd;
            const type_code = self.data[self.pos];
            const field_code = self.data[self.pos + 1];
            self.pos += 2;
            return .{ .type_code = type_code, .field_code = field_code };
        }
    }

    /// Parse XRPL variable-length prefix, returning the decoded length.
    pub fn parseVLLength(self: *CanonicalDeserializer) !usize {
        if (self.pos >= self.data.len) return error.UnexpectedEnd;
        const first = self.data[self.pos];
        self.pos += 1;

        if (first <= 192) {
            return @as(usize, first);
        } else if (first <= 240) {
            if (self.pos >= self.data.len) return error.UnexpectedEnd;
            const second = self.data[self.pos];
            self.pos += 1;
            return @as(usize, 193) + @as(usize, first - 193) * 256 + @as(usize, second);
        } else {
            if (self.pos + 2 > self.data.len) return error.UnexpectedEnd;
            const second = self.data[self.pos];
            const third = self.data[self.pos + 1];
            self.pos += 2;
            return @as(usize, 12481) + @as(usize, first - 241) * 65536 + @as(usize, second) * 256 + @as(usize, third);
        }
    }

    /// Parse an Amount field. Returns the raw drops value for XRP amounts.
    /// XRP amounts have bit 63 clear, bit 62 set (positive).
    /// IOU amounts have bit 63 set -- skips 40 more bytes (currency + issuer).
    pub fn parseAmount(self: *CanonicalDeserializer) !struct { drops: u64, is_iou: bool } {
        if (self.pos + 8 > self.data.len) return error.UnexpectedEnd;
        const raw = std.mem.readInt(u64, self.data[self.pos..][0..8], .big);
        self.pos += 8;

        const is_iou = (raw & (@as(u64, 1) << 63)) != 0;
        if (is_iou) {
            if (self.pos + 40 > self.data.len) return error.UnexpectedEnd;
            self.pos += 40;
            return .{ .drops = 0, .is_iou = true };
        }

        const drops = raw & 0x3FFFFFFFFFFFFFFF;
        return .{ .drops = drops, .is_iou = false };
    }

    /// Read exactly `n` raw bytes from the buffer (borrowed slice).
    fn readBytes(self: *CanonicalDeserializer, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEnd;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    /// Deserialize binary XRPL data into a TransactionJSON.
    pub fn deserialize(self: *CanonicalDeserializer) !@import("canonical_tx.zig").TransactionJSON {
        const canonical_tx = @import("canonical_tx.zig");
        var tx = canonical_tx.TransactionJSON{};

        while (self.pos < self.data.len) {
            const header = try self.parseFieldHeader();

            switch (header.type_code) {
                TypeCode.UInt16 => {
                    const bytes = try self.readBytes(2);
                    const val = std.mem.readInt(u16, bytes[0..2], .big);
                    if (header.field_code == 2) {
                        tx.TransactionType = txCodeToName(val);
                    }
                },
                TypeCode.UInt32 => {
                    const bytes4 = try self.readBytes(4);
                    const val = std.mem.readInt(u32, bytes4[0..4], .big);
                    switch (header.field_code) {
                        2 => tx.Flags = val,
                        4 => tx.Sequence = val,
                        5, 18 => tx.SetFlag = val, // field 5 (XRPL spec) or 18 (legacy)
                        6, 19 => tx.ClearFlag = val, // field 6 (XRPL spec) or 19 (legacy)
                        9, 25 => tx.OfferSequence = val, // field 9 (XRPL spec) or 25 (legacy)
                        10 => tx.Expiration = val,
                        11 => tx.TransferRate = val,
                        14 => tx.DestinationTag = val,
                        27 => tx.LastLedgerSequence = val,
                        else => {},
                    }
                },
                TypeCode.UInt64 => {
                    _ = try self.readBytes(8);
                },
                TypeCode.Hash128 => {
                    _ = try self.readBytes(16);
                },
                TypeCode.Hash256 => {
                    _ = try self.readBytes(32);
                },
                TypeCode.Amount => {
                    const amount = try self.parseAmount();
                    if (!amount.is_iou) {
                        var buf: [20]u8 = undefined;
                        const drops_str = std.fmt.bufPrint(&buf, "{d}", .{amount.drops}) catch unreachable;
                        const owned = try self.allocator.dupe(u8, drops_str);
                        const assigned = blk: {
                            switch (header.field_code) {
                                8 => {
                                    tx.Fee = owned;
                                    break :blk true;
                                },
                                9 => {
                                    tx.SendMax = owned;
                                    break :blk true;
                                },
                                1 => {
                                    // field 1 = Amount for Payment, TakerPays for OfferCreate
                                    if (tx.TransactionType) |tt| {
                                        if (std.mem.eql(u8, tt, "OfferCreate")) {
                                            tx.TakerPays = owned;
                                            break :blk true;
                                        }
                                    }
                                    tx.Amount = owned;
                                    break :blk true;
                                },
                                2 => {
                                    // field 2 = TakerGets for OfferCreate
                                    tx.TakerGets = owned;
                                    break :blk true;
                                },
                                4 => {
                                    tx.TakerPays = owned;
                                    break :blk true;
                                },
                                5 => {
                                    tx.TakerGets = owned;
                                    break :blk true;
                                },
                                else => break :blk false,
                            }
                        };
                        if (!assigned) self.allocator.free(owned);
                    }
                },
                TypeCode.Blob => {
                    const vl_len = try self.parseVLLength();
                    _ = try self.readBytes(vl_len);
                },
                TypeCode.AccountID => {
                    const vl_len = try self.parseVLLength();
                    if (vl_len != 20) return error.InvalidAccountID;
                    const account_bytes = try self.readBytes(20);
                    var account_id: types.AccountID = undefined;
                    @memcpy(&account_id, account_bytes);
                    const base58 = @import("base58.zig");
                    const address = try base58.Base58.encodeAccountID(self.allocator, account_id);
                    switch (header.field_code) {
                        1 => tx.Account = address,
                        3 => tx.Destination = address,
                        else => self.allocator.free(address),
                    }
                },
                else => return error.UnsupportedType,
            }
        }

        return tx;
    }

    /// Free any allocator-owned strings inside a TransactionJSON returned by deserialize().
    pub fn freeTransactionJSON(allocator: std.mem.Allocator, tx: *const @import("canonical_tx.zig").TransactionJSON) void {
        if (tx.Amount) |s| allocator.free(s);
        if (tx.Fee) |s| allocator.free(s);
        if (tx.SendMax) |s| allocator.free(s);
        if (tx.TakerPays) |s| allocator.free(s);
        if (tx.TakerGets) |s| allocator.free(s);
        if (tx.Account) |s| allocator.free(s);
        if (tx.Destination) |s| allocator.free(s);
    }
};

/// Reverse lookup: transaction type code to name string (compile-time literals).
fn txCodeToName(code: u16) ?[]const u8 {
    return switch (code) {
        0 => "Payment",
        1 => "EscrowCreate",
        2 => "EscrowFinish",
        3 => "AccountSet",
        4 => "EscrowCancel",
        5 => "SetRegularKey",
        6 => "NickNameSet",
        7 => "OfferCreate",
        8 => "OfferCancel",
        12 => "SignerListSet",
        13 => "PaymentChannelCreate",
        14 => "PaymentChannelFund",
        15 => "PaymentChannelClaim",
        16 => "CheckCreate",
        17 => "CheckCash",
        18 => "CheckCancel",
        20 => "TrustSet",
        25 => "NFTokenMint",
        26 => "NFTokenBurn",
        27 => "NFTokenCreateOffer",
        28 => "NFTokenCancelOffer",
        29 => "NFTokenAcceptOffer",
        else => null,
    };
}

// ── Deserializer Tests ──

test "parseFieldHeader single byte" {
    var deser = CanonicalDeserializer.init(std.testing.allocator, &[_]u8{0x12});
    const hdr = try deser.parseFieldHeader();
    try std.testing.expectEqual(@as(u8, 1), hdr.type_code);
    try std.testing.expectEqual(@as(u8, 2), hdr.field_code);
    std.debug.print("[PASS] parseFieldHeader single byte\n", .{});
}

test "parseFieldHeader two byte type<16 field>=16" {
    var deser = CanonicalDeserializer.init(std.testing.allocator, &[_]u8{ 0x20, 0x14 });
    const hdr = try deser.parseFieldHeader();
    try std.testing.expectEqual(@as(u8, 2), hdr.type_code);
    try std.testing.expectEqual(@as(u8, 20), hdr.field_code);
    std.debug.print("[PASS] parseFieldHeader two byte (type<16, field>=16)\n", .{});
}

test "parseFieldHeader two byte type>=16 field<16" {
    var deser = CanonicalDeserializer.init(std.testing.allocator, &[_]u8{ 0x03, 0x10 });
    const hdr = try deser.parseFieldHeader();
    try std.testing.expectEqual(@as(u8, 16), hdr.type_code);
    try std.testing.expectEqual(@as(u8, 3), hdr.field_code);
    std.debug.print("[PASS] parseFieldHeader two byte (type>=16, field<16)\n", .{});
}

test "parseFieldHeader three byte" {
    var deser = CanonicalDeserializer.init(std.testing.allocator, &[_]u8{ 0x00, 0x10, 0x10 });
    const hdr = try deser.parseFieldHeader();
    try std.testing.expectEqual(@as(u8, 16), hdr.type_code);
    try std.testing.expectEqual(@as(u8, 16), hdr.field_code);
    std.debug.print("[PASS] parseFieldHeader three byte\n", .{});
}

test "parseVLLength single byte" {
    var deser = CanonicalDeserializer.init(std.testing.allocator, &[_]u8{20});
    const len = try deser.parseVLLength();
    try std.testing.expectEqual(@as(usize, 20), len);
    std.debug.print("[PASS] parseVLLength single byte\n", .{});
}

test "parseAmount XRP" {
    var deser = CanonicalDeserializer.init(std.testing.allocator, &[_]u8{ 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64 });
    const result = try deser.parseAmount();
    try std.testing.expectEqual(false, result.is_iou);
    try std.testing.expectEqual(@as(u64, 100), result.drops);
    std.debug.print("[PASS] parseAmount XRP (100 drops)\n", .{});
}

test "round-trip: serialize then deserialize payment" {
    const allocator = std.testing.allocator;
    const canonical_tx = @import("canonical_tx.zig");

    const tx_in = canonical_tx.TransactionJSON{
        .TransactionType = "Payment",
        .Sequence = 1,
        .DestinationTag = 7,
        .Amount = "100",
        .Fee = "10",
    };

    var ser = try canonical_tx.CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();
    const serialized = try ser.serializeForSigning(tx_in);
    defer allocator.free(serialized);

    var deser = CanonicalDeserializer.init(allocator, serialized);
    const tx_out = try deser.deserialize();
    defer CanonicalDeserializer.freeTransactionJSON(allocator, &tx_out);

    try std.testing.expectEqualStrings("Payment", tx_out.TransactionType.?);
    try std.testing.expectEqual(@as(u32, 1), tx_out.Sequence.?);
    try std.testing.expectEqual(@as(u32, 7), tx_out.DestinationTag.?);
    try std.testing.expectEqualStrings("100", tx_out.Amount.?);
    try std.testing.expectEqualStrings("10", tx_out.Fee.?);

    std.debug.print("[PASS] Round-trip: serialize then deserialize Payment\n", .{});
}

test "round-trip: serialize then deserialize OfferCreate" {
    const allocator = std.testing.allocator;
    const canonical_tx = @import("canonical_tx.zig");

    const tx_in = canonical_tx.TransactionJSON{
        .TransactionType = "OfferCreate",
        .Sequence = 3,
        .Expiration = 9,
        .TakerPays = "200",
        .TakerGets = "300",
        .Fee = "10",
    };

    var ser = try canonical_tx.CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();
    const serialized = try ser.serializeForSigning(tx_in);
    defer allocator.free(serialized);

    var deser = CanonicalDeserializer.init(allocator, serialized);
    const tx_out = try deser.deserialize();
    defer CanonicalDeserializer.freeTransactionJSON(allocator, &tx_out);

    try std.testing.expectEqualStrings("OfferCreate", tx_out.TransactionType.?);
    try std.testing.expectEqual(@as(u32, 3), tx_out.Sequence.?);
    try std.testing.expectEqual(@as(u32, 9), tx_out.Expiration.?);
    try std.testing.expectEqualStrings("200", tx_out.TakerPays.?);
    try std.testing.expectEqualStrings("300", tx_out.TakerGets.?);
    try std.testing.expectEqualStrings("10", tx_out.Fee.?);

    std.debug.print("[PASS] Round-trip: serialize then deserialize OfferCreate\n", .{});
}

test "round-trip: serialize then deserialize AccountSet" {
    const allocator = std.testing.allocator;
    const canonical_tx = @import("canonical_tx.zig");

    const tx_in = canonical_tx.TransactionJSON{
        .TransactionType = "AccountSet",
        .Sequence = 2,
        .SetFlag = 2,
        .ClearFlag = 1,
        .TransferRate = 7,
        .Fee = "10",
    };

    var ser = try canonical_tx.CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();
    const serialized = try ser.serializeForSigning(tx_in);
    defer allocator.free(serialized);

    var deser = CanonicalDeserializer.init(allocator, serialized);
    const tx_out = try deser.deserialize();
    defer CanonicalDeserializer.freeTransactionJSON(allocator, &tx_out);

    try std.testing.expectEqualStrings("AccountSet", tx_out.TransactionType.?);
    try std.testing.expectEqual(@as(u32, 2), tx_out.Sequence.?);
    try std.testing.expectEqual(@as(u32, 2), tx_out.SetFlag.?);
    try std.testing.expectEqual(@as(u32, 1), tx_out.ClearFlag.?);
    try std.testing.expectEqual(@as(u32, 7), tx_out.TransferRate.?);
    try std.testing.expectEqualStrings("10", tx_out.Fee.?);

    std.debug.print("[PASS] Round-trip: serialize then deserialize AccountSet\n", .{});
}

test "round-trip: serialize then deserialize OfferCancel" {
    const allocator = std.testing.allocator;
    const canonical_tx = @import("canonical_tx.zig");

    const tx_in = canonical_tx.TransactionJSON{
        .TransactionType = "OfferCancel",
        .Sequence = 4,
        .OfferSequence = 55,
        .Fee = "10",
    };

    var ser = try canonical_tx.CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();
    const serialized = try ser.serializeForSigning(tx_in);
    defer allocator.free(serialized);

    var deser = CanonicalDeserializer.init(allocator, serialized);
    const tx_out = try deser.deserialize();
    defer CanonicalDeserializer.freeTransactionJSON(allocator, &tx_out);

    try std.testing.expectEqualStrings("OfferCancel", tx_out.TransactionType.?);
    try std.testing.expectEqual(@as(u32, 4), tx_out.Sequence.?);
    try std.testing.expectEqual(@as(u32, 55), tx_out.OfferSequence.?);
    try std.testing.expectEqualStrings("10", tx_out.Fee.?);

    std.debug.print("[PASS] Round-trip: serialize then deserialize OfferCancel\n", .{});
}

test "deserialize from known fixture hex (payment_basic)" {
    const allocator = std.testing.allocator;

    const hex = "12000024000000012e0000000761400000000000006468400000000000000a8114010101010101010101010101010101010101010183140202020202020202020202020202020202020202";
    var bin: [75]u8 = undefined;
    for (0..75) |i| {
        bin[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }

    var deser = CanonicalDeserializer.init(allocator, &bin);
    const tx = try deser.deserialize();
    defer CanonicalDeserializer.freeTransactionJSON(allocator, &tx);

    try std.testing.expectEqualStrings("Payment", tx.TransactionType.?);
    try std.testing.expectEqual(@as(u32, 1), tx.Sequence.?);
    try std.testing.expectEqual(@as(u32, 7), tx.DestinationTag.?);
    try std.testing.expectEqualStrings("100", tx.Amount.?);
    try std.testing.expectEqualStrings("10", tx.Fee.?);
    try std.testing.expect(tx.Account != null);
    try std.testing.expect(tx.Destination != null);

    std.debug.print("[PASS] Deserialize from known fixture hex (payment_basic)\n", .{});
}

test "deserialize from known fixture hex (account_set_with_flags)" {
    const allocator = std.testing.allocator;

    const hex = "1200032400000002250000000226000000012b0000000768400000000000000a81140303030303030303030303030303030303030303";
    const expected_len = 54;
    var bin: [expected_len]u8 = undefined;
    for (0..expected_len) |i| {
        bin[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }

    var deser = CanonicalDeserializer.init(allocator, &bin);
    const tx = try deser.deserialize();
    defer CanonicalDeserializer.freeTransactionJSON(allocator, &tx);

    try std.testing.expectEqualStrings("AccountSet", tx.TransactionType.?);
    try std.testing.expectEqual(@as(u32, 2), tx.Sequence.?);
    try std.testing.expectEqual(@as(u32, 2), tx.SetFlag.?);
    try std.testing.expectEqual(@as(u32, 1), tx.ClearFlag.?);
    try std.testing.expectEqual(@as(u32, 7), tx.TransferRate.?);
    try std.testing.expectEqualStrings("10", tx.Fee.?);
    try std.testing.expect(tx.Account != null);

    std.debug.print("[PASS] Deserialize from known fixture hex (account_set_with_flags)\n", .{});
}

test "deserialize from known fixture hex (offer_create_with_expiration)" {
    const allocator = std.testing.allocator;

    const hex = "12000724000000032a000000096140000000000000c862400000000000012c68400000000000000a81140404040404040404040404040404040404040404";
    const expected_len = 62;
    var bin: [expected_len]u8 = undefined;
    for (0..expected_len) |i| {
        bin[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }

    var deser = CanonicalDeserializer.init(allocator, &bin);
    const tx = try deser.deserialize();
    defer CanonicalDeserializer.freeTransactionJSON(allocator, &tx);

    try std.testing.expectEqualStrings("OfferCreate", tx.TransactionType.?);
    try std.testing.expectEqual(@as(u32, 3), tx.Sequence.?);
    try std.testing.expectEqual(@as(u32, 9), tx.Expiration.?);
    try std.testing.expectEqualStrings("200", tx.TakerPays.?);
    try std.testing.expectEqualStrings("300", tx.TakerGets.?);
    try std.testing.expectEqualStrings("10", tx.Fee.?);
    try std.testing.expect(tx.Account != null);

    std.debug.print("[PASS] Deserialize from known fixture hex (offer_create_with_expiration)\n", .{});
}

test "deserialize from known fixture hex (offer_cancel)" {
    const allocator = std.testing.allocator;

    const hex = "1200082400000004290000003768400000000000000a81140505050505050505050505050505050505050505";
    const expected_len = 44;
    var bin: [expected_len]u8 = undefined;
    for (0..expected_len) |i| {
        bin[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }

    var deser = CanonicalDeserializer.init(allocator, &bin);
    const tx = try deser.deserialize();
    defer CanonicalDeserializer.freeTransactionJSON(allocator, &tx);

    try std.testing.expectEqualStrings("OfferCancel", tx.TransactionType.?);
    try std.testing.expectEqual(@as(u32, 4), tx.Sequence.?);
    try std.testing.expectEqual(@as(u32, 55), tx.OfferSequence.?);
    try std.testing.expectEqualStrings("10", tx.Fee.?);
    try std.testing.expect(tx.Account != null);

    std.debug.print("[PASS] Deserialize from known fixture hex (offer_cancel)\n", .{});
}
