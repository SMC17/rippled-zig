const std = @import("std");
const rpc_methods = @import("rpc_methods.zig");
const rpc_complete = @import("rpc_complete.zig");
const ledger = @import("ledger.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

// Comprehensive RPC Method Tests
// Based on rippled RPC tests
// Validates all API methods and error handling

test "RPC: account_info with valid account" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    // Create account
    const account = [_]u8{1} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 5,
    });

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const result = try methods.accountInfo(account);
    defer allocator.free(result);

    // Should contain balance
    try std.testing.expect(std.mem.indexOf(u8, result, "1000000000") != null);
    // Should contain sequence
    try std.testing.expect(std.mem.indexOf(u8, result, "\"Sequence\": 5") != null);
}

test "RPC: account_info with non-existent account" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const missing_account = [_]u8{99} ** 20;
    const result = try methods.accountInfo(missing_account);
    defer allocator.free(result);

    // Should return error
    try std.testing.expect(std.mem.indexOf(u8, result, "actNotFound") != null);
}

test "RPC: server_info response format" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const result = try methods.serverInfo(12345);
    defer allocator.free(result);

    // Verify required fields
    try std.testing.expect(std.mem.indexOf(u8, result, "build_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "complete_ledgers") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ledger_seq") != null);
}

test "RPC: fee method" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const result = try methods.fee();
    defer allocator.free(result);

    // Should contain fee levels
    try std.testing.expect(std.mem.indexOf(u8, result, "base_fee") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "median_fee") != null);
}

test "RPC: ledger_current" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const result = try methods.ledgerCurrent();
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "ledger_current_index") != null);
}

test "RPC: agent control status and config" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const set_result = try methods.agentConfigSet("fee_multiplier", "3");
    defer allocator.free(set_result);
    try std.testing.expect(std.mem.indexOf(u8, set_result, "\"status\": \"success\"") != null);

    const get_result = try methods.agentConfigGet();
    defer allocator.free(get_result);
    try std.testing.expect(std.mem.indexOf(u8, get_result, "\"fee_multiplier\": 3") != null);

    const status_result = try methods.agentStatus(9001);
    defer allocator.free(status_result);
    try std.testing.expect(std.mem.indexOf(u8, status_result, "\"agent_control\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result, "\"uptime\": 9001") != null);
}
