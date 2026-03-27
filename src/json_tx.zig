const std = @import("std");
const canonical_tx = @import("canonical_tx.zig");

/// Parse an XRPL transaction JSON string into a TransactionJSON struct.
/// Supports all fields in the TransactionJSON struct.
/// Unknown fields are silently ignored (forward compatibility).
pub fn parseTransactionJSON(allocator: std.mem.Allocator, json_str: []const u8) !canonical_tx.TransactionJSON {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    const obj = root.object;

    var tx = canonical_tx.TransactionJSON{};

    // String fields
    tx.TransactionType = try dupeJsonString(allocator, obj, "TransactionType");
    tx.Account = try dupeJsonString(allocator, obj, "Account");
    tx.Fee = try dupeJsonString(allocator, obj, "Fee");
    tx.SigningPubKey = try dupeJsonString(allocator, obj, "SigningPubKey");
    tx.TxnSignature = try dupeJsonString(allocator, obj, "TxnSignature");
    tx.hash = try dupeJsonString(allocator, obj, "hash");
    tx.Destination = try dupeJsonString(allocator, obj, "Destination");
    tx.SendMax = try resolveAmountField(allocator, obj, "SendMax");
    tx.Amount = try resolveAmountField(allocator, obj, "Amount");
    tx.TakerPays = try resolveAmountField(allocator, obj, "TakerPays");
    tx.TakerGets = try resolveAmountField(allocator, obj, "TakerGets");
    tx.Domain = try dupeJsonString(allocator, obj, "Domain");
    tx.SignerEntries = try dupeJsonString(allocator, obj, "SignerEntries");

    // Integer fields
    tx.Sequence = getJsonU32(obj, "Sequence");
    tx.Flags = getJsonU32(obj, "Flags");
    tx.LastLedgerSequence = getJsonU32(obj, "LastLedgerSequence");
    tx.DestinationTag = getJsonU32(obj, "DestinationTag");
    tx.Expiration = getJsonU32(obj, "Expiration");
    tx.OfferSequence = getJsonU32(obj, "OfferSequence");
    tx.SetFlag = getJsonU32(obj, "SetFlag");
    tx.ClearFlag = getJsonU32(obj, "ClearFlag");
    tx.TransferRate = getJsonU32(obj, "TransferRate");
    tx.SignerQuorum = getJsonU32(obj, "SignerQuorum");

    return tx;
}

/// Serialize a TransactionJSON back to JSON string
pub fn toJSON(allocator: std.mem.Allocator, tx: canonical_tx.TransactionJSON) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{");
    var first = true;

    // String fields
    try appendStringField(&buf, "TransactionType", tx.TransactionType, &first);
    try appendStringField(&buf, "Account", tx.Account, &first);
    try appendStringField(&buf, "Fee", tx.Fee, &first);
    try appendStringField(&buf, "SigningPubKey", tx.SigningPubKey, &first);
    try appendStringField(&buf, "TxnSignature", tx.TxnSignature, &first);
    try appendStringField(&buf, "hash", tx.hash, &first);
    try appendStringField(&buf, "Destination", tx.Destination, &first);
    try appendStringField(&buf, "Amount", tx.Amount, &first);
    try appendStringField(&buf, "SendMax", tx.SendMax, &first);
    try appendStringField(&buf, "TakerPays", tx.TakerPays, &first);
    try appendStringField(&buf, "TakerGets", tx.TakerGets, &first);
    try appendStringField(&buf, "Domain", tx.Domain, &first);
    try appendStringField(&buf, "SignerEntries", tx.SignerEntries, &first);

    // Integer fields
    try appendU32Field(&buf, "Sequence", tx.Sequence, &first);
    try appendU32Field(&buf, "Flags", tx.Flags, &first);
    try appendU32Field(&buf, "LastLedgerSequence", tx.LastLedgerSequence, &first);
    try appendU32Field(&buf, "DestinationTag", tx.DestinationTag, &first);
    try appendU32Field(&buf, "Expiration", tx.Expiration, &first);
    try appendU32Field(&buf, "OfferSequence", tx.OfferSequence, &first);
    try appendU32Field(&buf, "SetFlag", tx.SetFlag, &first);
    try appendU32Field(&buf, "ClearFlag", tx.ClearFlag, &first);
    try appendU32Field(&buf, "TransferRate", tx.TransferRate, &first);
    try appendU32Field(&buf, "SignerQuorum", tx.SignerQuorum, &first);

    try buf.appendSlice("}");

    return buf.toOwnedSlice();
}

/// Free all allocator-owned strings in a parsed TransactionJSON
pub fn freeTransactionJSON(allocator: std.mem.Allocator, tx: *canonical_tx.TransactionJSON) void {
    freeOptionalString(allocator, tx.TransactionType);
    freeOptionalString(allocator, tx.Account);
    freeOptionalString(allocator, tx.Fee);
    freeOptionalString(allocator, tx.SigningPubKey);
    freeOptionalString(allocator, tx.TxnSignature);
    freeOptionalString(allocator, tx.hash);
    freeOptionalString(allocator, tx.Destination);
    freeOptionalString(allocator, tx.Amount);
    freeOptionalString(allocator, tx.SendMax);
    freeOptionalString(allocator, tx.TakerPays);
    freeOptionalString(allocator, tx.TakerGets);
    freeOptionalString(allocator, tx.Domain);
    freeOptionalString(allocator, tx.SignerEntries);

    tx.* = canonical_tx.TransactionJSON{};
}

// ── Internal helpers ──

fn freeOptionalString(allocator: std.mem.Allocator, opt: ?[]const u8) void {
    if (opt) |s| {
        allocator.free(s);
    }
}

fn dupeJsonString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const val = obj.get(key) orelse return null;
    switch (val) {
        .string => |s| return try allocator.dupe(u8, s),
        else => return null,
    }
}

fn getJsonU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const val = obj.get(key) orelse return null;
    switch (val) {
        .integer => |i| {
            if (i < 0 or i > std.math.maxInt(u32)) return null;
            return @intCast(i);
        },
        else => return null,
    }
}

/// Resolve an Amount field: if string, treat as XRP drops; if object with
/// "currency"/"issuer"/"value", format as "value/currency/issuer" IOU string.
fn resolveAmountField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const val = obj.get(key) orelse return null;
    switch (val) {
        .string => |s| return try allocator.dupe(u8, s),
        .object => |amount_obj| {
            const currency = amount_obj.get("currency") orelse return null;
            const issuer = amount_obj.get("issuer") orelse return null;
            const value = amount_obj.get("value") orelse return null;

            const currency_str = switch (currency) {
                .string => |s| s,
                else => return null,
            };
            const issuer_str = switch (issuer) {
                .string => |s| s,
                else => return null,
            };
            const value_str = switch (value) {
                .string => |s| s,
                else => return null,
            };

            return try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ value_str, currency_str, issuer_str });
        },
        else => return null,
    }
}

fn appendStringField(buf: *std.ArrayList(u8), key: []const u8, value: ?[]const u8, first: *bool) !void {
    const v = value orelse return;
    if (!first.*) {
        try buf.appendSlice(",");
    }
    first.* = false;
    try buf.appendSlice("\"");
    try buf.appendSlice(key);
    try buf.appendSlice("\":\"");
    try appendEscaped(buf, v);
    try buf.appendSlice("\"");
}

fn appendU32Field(buf: *std.ArrayList(u8), key: []const u8, value: ?u32, first: *bool) !void {
    const v = value orelse return;
    if (!first.*) {
        try buf.appendSlice(",");
    }
    first.* = false;
    try buf.appendSlice("\"");
    try buf.appendSlice(key);
    try buf.appendSlice("\":");
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(num_str);
}

fn appendEscaped(buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => try buf.append(c),
        }
    }
}

// ── Tests ──

test "parse Payment transaction JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "TransactionType": "Payment",
        \\  "Account": "rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T",
        \\  "Destination": "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh",
        \\  "Amount": "1000000",
        \\  "Fee": "12",
        \\  "Sequence": 1,
        \\  "Flags": 2147483648,
        \\  "LastLedgerSequence": 100
        \\}
    ;

    var tx = try parseTransactionJSON(allocator, json);
    defer freeTransactionJSON(allocator, &tx);

    try std.testing.expectEqualStrings("Payment", tx.TransactionType.?);
    try std.testing.expectEqualStrings("rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T", tx.Account.?);
    try std.testing.expectEqualStrings("rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", tx.Destination.?);
    try std.testing.expectEqualStrings("1000000", tx.Amount.?);
    try std.testing.expectEqualStrings("12", tx.Fee.?);
    try std.testing.expectEqual(@as(u32, 1), tx.Sequence.?);
    try std.testing.expectEqual(@as(u32, 2147483648), tx.Flags.?);
    try std.testing.expectEqual(@as(u32, 100), tx.LastLedgerSequence.?);

    std.debug.print("[PASS] parse Payment transaction JSON\n", .{});
}

test "parse OfferCreate transaction JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "TransactionType": "OfferCreate",
        \\  "Account": "rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T",
        \\  "TakerPays": "5000000",
        \\  "TakerGets": {"currency": "USD", "issuer": "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", "value": "100"},
        \\  "Fee": "10",
        \\  "Sequence": 42,
        \\  "Expiration": 570000000
        \\}
    ;

    var tx = try parseTransactionJSON(allocator, json);
    defer freeTransactionJSON(allocator, &tx);

    try std.testing.expectEqualStrings("OfferCreate", tx.TransactionType.?);
    try std.testing.expectEqualStrings("5000000", tx.TakerPays.?);
    // IOU amount formatted as "value/currency/issuer"
    try std.testing.expectEqualStrings("100/USD/rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", tx.TakerGets.?);
    try std.testing.expectEqual(@as(u32, 42), tx.Sequence.?);
    try std.testing.expectEqual(@as(u32, 570000000), tx.Expiration.?);

    std.debug.print("[PASS] parse OfferCreate transaction JSON\n", .{});
}

test "round-trip: toJSON then parseTransactionJSON produces equivalent output" {
    const allocator = std.testing.allocator;

    const json =
        \\{"TransactionType":"Payment","Account":"rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T","Fee":"12","Destination":"rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh","Amount":"1000000","Sequence":1,"Flags":2147483648}
    ;

    var tx1 = try parseTransactionJSON(allocator, json);
    defer freeTransactionJSON(allocator, &tx1);

    const serialized = try toJSON(allocator, tx1);
    defer allocator.free(serialized);

    var tx2 = try parseTransactionJSON(allocator, serialized);
    defer freeTransactionJSON(allocator, &tx2);

    try std.testing.expectEqualStrings(tx1.TransactionType.?, tx2.TransactionType.?);
    try std.testing.expectEqualStrings(tx1.Account.?, tx2.Account.?);
    try std.testing.expectEqualStrings(tx1.Fee.?, tx2.Fee.?);
    try std.testing.expectEqualStrings(tx1.Destination.?, tx2.Destination.?);
    try std.testing.expectEqualStrings(tx1.Amount.?, tx2.Amount.?);
    try std.testing.expectEqual(tx1.Sequence, tx2.Sequence);
    try std.testing.expectEqual(tx1.Flags, tx2.Flags);

    std.debug.print("[PASS] round-trip toJSON/parseTransactionJSON\n", .{});
}

test "handle missing optional fields gracefully" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "TransactionType": "Payment",
        \\  "Account": "rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T"
        \\}
    ;

    var tx = try parseTransactionJSON(allocator, json);
    defer freeTransactionJSON(allocator, &tx);

    try std.testing.expectEqualStrings("Payment", tx.TransactionType.?);
    try std.testing.expectEqualStrings("rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T", tx.Account.?);
    try std.testing.expect(tx.Fee == null);
    try std.testing.expect(tx.Destination == null);
    try std.testing.expect(tx.Amount == null);
    try std.testing.expect(tx.Sequence == null);
    try std.testing.expect(tx.Flags == null);
    try std.testing.expect(tx.LastLedgerSequence == null);
    try std.testing.expect(tx.DestinationTag == null);
    try std.testing.expect(tx.TakerPays == null);
    try std.testing.expect(tx.TakerGets == null);

    std.debug.print("[PASS] handle missing optional fields\n", .{});
}

test "handle unknown fields without error" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "TransactionType": "Payment",
        \\  "Account": "rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T",
        \\  "Fee": "12",
        \\  "Sequence": 1,
        \\  "FutureField": "some_value",
        \\  "AnotherUnknown": 42,
        \\  "NestedUnknown": {"a": 1, "b": 2}
        \\}
    ;

    var tx = try parseTransactionJSON(allocator, json);
    defer freeTransactionJSON(allocator, &tx);

    try std.testing.expectEqualStrings("Payment", tx.TransactionType.?);
    try std.testing.expectEqualStrings("rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T", tx.Account.?);
    try std.testing.expectEqualStrings("12", tx.Fee.?);
    try std.testing.expectEqual(@as(u32, 1), tx.Sequence.?);

    std.debug.print("[PASS] handle unknown fields without error\n", .{});
}
