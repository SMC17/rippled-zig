const std = @import("std");
const ledger = @import("ledger.zig");
const rpc_methods = @import("rpc_methods.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

fn requireContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return error.MissingExpectedField;
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
    try requireContains(account_info, "\"result\"");
    try requireContains(account_info, "\"account_data\"");
    try requireContains(account_info, "\"Account\"");
    try requireContains(account_info, "\"Balance\"");
    try requireContains(account_info, "\"Sequence\"");

    const server_info = try rpc.serverInfo(1000);
    defer allocator.free(server_info);
    try requireContains(server_info, "\"build_version\"");
    try requireContains(server_info, "\"validated_ledger\"");
    try requireContains(server_info, "\"server_state\"");

    const fee = try rpc.fee();
    defer allocator.free(fee);
    try requireContains(fee, "\"base_fee\"");
    try requireContains(fee, "\"median_fee\"");
    try requireContains(fee, "\"minimum_fee\"");

    const fixture_server = try std.fs.cwd().readFileAlloc(allocator, "test_data/server_info.json", 512 * 1024);
    defer allocator.free(fixture_server);
    const fixture_fee = try std.fs.cwd().readFileAlloc(allocator, "test_data/fee_info.json", 512 * 1024);
    defer allocator.free(fixture_fee);
    const fixture_acct = try std.fs.cwd().readFileAlloc(allocator, "test_data/account_info.json", 512 * 1024);
    defer allocator.free(fixture_acct);

    try requireContains(fixture_server, "validated_ledger");
    try requireContains(fixture_server, "server_state");
    try requireContains(fixture_fee, "base_fee");

    const has_account_data = std.mem.indexOf(u8, fixture_acct, "account_data") != null;
    const has_error_payload = std.mem.indexOf(u8, fixture_acct, "\"error\"") != null and std.mem.indexOf(u8, fixture_acct, "\"status\": \"error\"") != null;
    if (!(has_account_data or has_error_payload)) return error.InvalidAccountFixtureShape;
}
