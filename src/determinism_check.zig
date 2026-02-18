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
