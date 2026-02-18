const std = @import("std");
const ledger = @import("ledger.zig");
const rpc_methods = @import("rpc_methods.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "Gate C: account_info returns rippled-style keys" {
    const allocator = std.testing.allocator;

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
    const json = try rpc.accountInfo(account);
    defer allocator.free(json);

    try expectContains(json, "\"result\"");
    try expectContains(json, "\"account_data\"");
    try expectContains(json, "\"Account\"");
    try expectContains(json, "\"Balance\"");
    try expectContains(json, "\"Sequence\"");
    try expectContains(json, "\"status\": \"success\"");
}

test "Gate C: server_info and fee contain required fields" {
    const allocator = std.testing.allocator;

    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var rpc = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const server_info = try rpc.serverInfo(1000);
    defer allocator.free(server_info);

    try expectContains(server_info, "\"build_version\"");
    try expectContains(server_info, "\"validated_ledger\"");
    try expectContains(server_info, "\"server_state\"");

    const fee = try rpc.fee();
    defer allocator.free(fee);

    try expectContains(fee, "\"base_fee\"");
    try expectContains(fee, "\"median_fee\"");
    try expectContains(fee, "\"minimum_fee\"");
}

test "Gate C: fixture payload contracts are present" {
    const allocator = std.testing.allocator;

    const server = try std.fs.cwd().readFileAlloc(allocator, "test_data/server_info.json", 512 * 1024);
    defer allocator.free(server);

    const fee = try std.fs.cwd().readFileAlloc(allocator, "test_data/fee_info.json", 512 * 1024);
    defer allocator.free(fee);

    const acct = try std.fs.cwd().readFileAlloc(allocator, "test_data/account_info.json", 512 * 1024);
    defer allocator.free(acct);

    try expectContains(server, "validated_ledger");
    try expectContains(server, "server_state");
    try expectContains(fee, "base_fee");
    try expectContains(acct, "account_data");
}
