const std = @import("std");
const crypto = @import("crypto.zig");
const canonical = @import("canonical.zig");
const types = @import("types.zig");

fn parseHex32(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidHexLength;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

fn parseHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHexLength;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn hashFixtureFile(path: []const u8, allocator: std.mem.Allocator) ![32]u8 {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(data);
    return crypto.Hash.sha512Half(data);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const input = "xrpl-determinism-check";
    const h1 = crypto.Hash.sha512Half(input);
    const h2 = crypto.Hash.sha512Half(input);
    if (!std.mem.eql(u8, &h1, &h2)) return error.NonDeterministicHash;

    var a = try canonical.CanonicalSerializer.init(allocator);
    defer a.deinit();
    try a.addUInt64(8, 10);
    try a.addUInt16(2, 0);
    try a.addUInt32(4, 1);
    const out_a = try a.finish();
    defer allocator.free(out_a);

    var b = try canonical.CanonicalSerializer.init(allocator);
    defer b.deinit();
    try b.addUInt16(2, 0);
    try b.addUInt32(4, 1);
    try b.addUInt64(8, 10);
    const out_b = try b.finish();
    defer allocator.free(out_b);

    if (!std.mem.eql(u8, out_a, out_b)) return error.NonDeterministicCanonicalOrder;

    const expected_serialized_hex = "120000240000000168000000000000000a";
    const expected_serialized = try parseHexAlloc(allocator, expected_serialized_hex);
    defer allocator.free(expected_serialized);
    if (!std.mem.eql(u8, out_a, expected_serialized)) return error.CanonicalVectorMismatch;

    const serialized_hash = crypto.Hash.sha512Half(out_a);
    const expected_hash = try parseHex32("5de074b79ec3d36ebd7e704c214cdbf464b74d2e45794f5f7cd24832fb654c90");
    if (!std.mem.eql(u8, &serialized_hash, &expected_hash)) return error.CanonicalHashVectorMismatch;

    // Additional canonical vector including AccountID field.
    const account_id = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05,
        0x06, 0x07, 0x08, 0x09, 0x0A,
        0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13, 0x14,
    };
    var c = try canonical.CanonicalSerializer.init(allocator);
    defer c.deinit();
    try c.addUInt16(2, 0);
    try c.addUInt32(4, 1);
    try c.addUInt64(8, 10);
    try c.addAccountID(1, account_id);
    const out_c = try c.finish();
    defer allocator.free(out_c);

    const expected_serialized_hex_2 = "120000240000000168000000000000000a810102030405060708090a0b0c0d0e0f1011121314";
    const expected_serialized_2 = try parseHexAlloc(allocator, expected_serialized_hex_2);
    defer allocator.free(expected_serialized_2);
    if (!std.mem.eql(u8, out_c, expected_serialized_2)) return error.CanonicalVector2Mismatch;

    const serialized_hash_2 = crypto.Hash.sha512Half(out_c);
    const expected_hash_2 = try parseHex32("09bd8a5ed82ddae1eeba4eb1a8ad4083ad59c6ece4b3e6443517eab7b85f6e2f");
    if (!std.mem.eql(u8, &serialized_hash_2, &expected_hash_2)) return error.CanonicalHashVector2Mismatch;

    // Third canonical vector: VL boundary encoding at 192/193 bytes.
    var vl_192_payload: [192]u8 = undefined;
    for (&vl_192_payload, 0..) |*byte, i| byte.* = @intCast(i);
    var vl_192 = try canonical.CanonicalSerializer.init(allocator);
    defer vl_192.deinit();
    try vl_192.addVL(3, &vl_192_payload);
    const out_vl_192 = try vl_192.finish();
    defer allocator.free(out_vl_192);
    if (out_vl_192.len != 194) return error.VL192UnexpectedLength;
    if (out_vl_192[0] != 0x73 or out_vl_192[1] != 0xC0) return error.VL192UnexpectedPrefix;
    if (!std.mem.eql(u8, out_vl_192[2..], &vl_192_payload)) return error.VL192PayloadMismatch;
    const out_vl_192_hash = crypto.Hash.sha512Half(out_vl_192);
    const expected_vl_192_hash = try parseHex32("2d12f8dafee6a41c108376601196fb2e30a20f2c566ddf7897cd34149906b19e");
    if (!std.mem.eql(u8, &out_vl_192_hash, &expected_vl_192_hash)) return error.VL192HashMismatch;

    var vl_193_payload: [193]u8 = undefined;
    for (&vl_193_payload, 0..) |*byte, i| byte.* = @intCast(i);
    var vl_193 = try canonical.CanonicalSerializer.init(allocator);
    defer vl_193.deinit();
    try vl_193.addVL(3, &vl_193_payload);
    const out_vl_193 = try vl_193.finish();
    defer allocator.free(out_vl_193);
    if (out_vl_193.len != 196) return error.VL193UnexpectedLength;
    if (out_vl_193[0] != 0x73 or out_vl_193[1] != 0xC1 or out_vl_193[2] != 0x00) return error.VL193UnexpectedPrefix;
    if (!std.mem.eql(u8, out_vl_193[3..], &vl_193_payload)) return error.VL193PayloadMismatch;
    const out_vl_193_hash = crypto.Hash.sha512Half(out_vl_193);
    const expected_vl_193_hash = try parseHex32("31ac058dc1677933d75d3c1cb878a09db093a058e0262728366e93ba1b39111a");
    if (!std.mem.eql(u8, &out_vl_193_hash, &expected_vl_193_hash)) return error.VL193HashMismatch;

    const fixtures = [_]struct { path: []const u8, expected_sha512_half_hex: []const u8 }{
        .{ .path = "test_data/current_ledger.json", .expected_sha512_half_hex = "e6fcf8db7b7f53f4cc854951603299702d142b32d776403f15b7e71e6db8c73c" },
        .{ .path = "test_data/server_info.json", .expected_sha512_half_hex = "217d7592a371f0efd670b95b16d1634841ed0a245d97f34386967ffa43c29236" },
        .{ .path = "test_data/fee_info.json", .expected_sha512_half_hex = "81f8d45439bd7766b58da374a9b67afbdfebf2b4ea96f24aca450dce4e5e429a" },
        .{ .path = "test_data/account_info.json", .expected_sha512_half_hex = "7622148fac1f791beb79dfed4d90c575887b75a604267abe6daf7c8f5eab893b" },
    };

    for (fixtures) |fixture| {
        const h = try hashFixtureFile(fixture.path, allocator);
        const expected = try parseHex32(fixture.expected_sha512_half_hex);
        if (!std.mem.eql(u8, &h, &expected)) return error.FixtureHashDrift;

        var all_zero = true;
        for (h) |byte| {
            if (byte != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return error.InvalidFixtureHash;
    }

    const amount = types.Amount.fromXRP(100 * types.XRP);
    if (!amount.isXRP()) return error.InvalidAmountModel;
}
