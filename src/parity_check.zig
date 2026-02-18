const std = @import("std");
const ledger = @import("ledger.zig");
const rpc_methods = @import("rpc_methods.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

fn getObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => error.ExpectedObject,
    };
}

fn getField(obj: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return obj.get(key) orelse error.MissingExpectedField;
}

fn expectString(value: std.json.Value) !void {
    switch (value) {
        .string => {},
        else => return error.ExpectedString,
    }
}

fn expectBool(value: std.json.Value) !void {
    switch (value) {
        .bool => {},
        else => return error.ExpectedBool,
    }
}

fn expectInteger(value: std.json.Value) !void {
    switch (value) {
        .integer => {},
        else => return error.ExpectedInteger,
    }
}

fn assertAccountInfoTypes(payload: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const root_obj = try getObject(root);
    const result_obj = try getObject(try getField(root_obj, "result"));
    const account_data = try getObject(try getField(result_obj, "account_data"));

    try expectString(try getField(account_data, "Account"));
    try expectString(try getField(account_data, "Balance"));
    try expectInteger(try getField(account_data, "Flags"));
    try expectInteger(try getField(account_data, "OwnerCount"));
    try expectInteger(try getField(account_data, "Sequence"));

    try expectString(try getField(result_obj, "status"));
    try expectBool(try getField(result_obj, "validated"));
}

fn assertServerInfoTypes(payload: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const root_obj = try getObject(root);
    const result_obj = try getObject(try getField(root_obj, "result"));
    const info_obj = try getObject(try getField(result_obj, "info"));
    const validated = try getObject(try getField(info_obj, "validated_ledger"));

    try expectString(try getField(info_obj, "build_version"));
    try expectString(try getField(info_obj, "server_state"));
    try expectInteger(try getField(info_obj, "network_id"));

    try expectString(try getField(validated, "hash"));
    try expectInteger(try getField(validated, "seq"));
}

fn assertFeeTypes(payload: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const root_obj = try getObject(root);
    const result_obj = try getObject(try getField(root_obj, "result"));
    const drops_obj = try getObject(try getField(result_obj, "drops"));

    try expectString(try getField(drops_obj, "base_fee"));
    try expectString(try getField(drops_obj, "median_fee"));
    try expectString(try getField(drops_obj, "minimum_fee"));
    try expectString(try getField(drops_obj, "open_ledger_fee"));

    try expectString(try getField(result_obj, "status"));
}

fn assertAccountFixtureShape(payload: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const root_obj = try getObject(root);
    const result_obj = try getObject(try getField(root_obj, "result"));

    if (result_obj.get("account_data")) |account_data_value| {
        const account_data = try getObject(account_data_value);
        try expectString(try getField(account_data, "Account"));
        return;
    }

    try expectString(try getField(result_obj, "error"));
    try expectString(try getField(result_obj, "status"));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const account = [_]u8{1} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 123 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 7,
    });

    var rpc = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const account_info = try rpc.accountInfo(account);
    defer allocator.free(account_info);
    try assertAccountInfoTypes(account_info, allocator);

    const server_info = try rpc.serverInfo(1000);
    defer allocator.free(server_info);
    try assertServerInfoTypes(server_info, allocator);

    const fee = try rpc.fee();
    defer allocator.free(fee);
    try assertFeeTypes(fee, allocator);

    const fixture_server = try std.fs.cwd().readFileAlloc(allocator, "test_data/server_info.json", 512 * 1024);
    defer allocator.free(fixture_server);
    const fixture_fee = try std.fs.cwd().readFileAlloc(allocator, "test_data/fee_info.json", 512 * 1024);
    defer allocator.free(fixture_fee);
    const fixture_acct = try std.fs.cwd().readFileAlloc(allocator, "test_data/account_info.json", 512 * 1024);
    defer allocator.free(fixture_acct);

    try assertServerInfoTypes(fixture_server, allocator);
    try assertFeeTypes(fixture_fee, allocator);
    try assertAccountFixtureShape(fixture_acct, allocator);
}
