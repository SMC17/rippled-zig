const std = @import("std");
const crypto = @import("crypto.zig");
const canonical = @import("canonical.zig");
const types = @import("types.zig");

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

    const files = [_][]const u8{
        "test_data/current_ledger.json",
        "test_data/server_info.json",
        "test_data/fee_info.json",
    };

    for (files) |path| {
        const h = try hashFixtureFile(path, allocator);
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
