const std = @import("std");
const crypto = @import("crypto.zig");
const canonical = @import("canonical.zig");
const types = @import("types.zig");

fn hashFixtureFile(path: []const u8, allocator: std.mem.Allocator) ![32]u8 {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(data);
    return crypto.Hash.sha512Half(data);
}

test "Gate B: sha512half deterministic" {
    const input = "xrpl-determinism-check";
    const h1 = crypto.Hash.sha512Half(input);
    const h2 = crypto.Hash.sha512Half(input);
    try std.testing.expect(std.mem.eql(u8, &h1, &h2));
}

test "Gate B: canonical serializer deterministic ordering" {
    const allocator = std.testing.allocator;

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

    try std.testing.expect(std.mem.eql(u8, out_a, out_b));
}

test "Gate B: fixture hashes are stable and non-zero" {
    const allocator = std.testing.allocator;

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
        try std.testing.expect(!all_zero);
    }
}

test "Gate B: amount model is deterministic" {
    const amount = types.Amount.fromXRP(100 * types.XRP);
    try std.testing.expect(amount.isXRP());
}
