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

test "RPC: submit AccountSet (34-byte minimal blob)" {
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
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 5,
    });

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    // Minimal AccountSet blob: tx_type=3, account (20), fee=10, sequence=5
    const blob = "00030101010101010101010101010101010101010101000000000000000A00000005";
    const result = try methods.submit(blob);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "tesSUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "AccountSet") != null);
    const acct = state.getAccount(account).?;
    try std.testing.expectEqual(@as(u32, 6), acct.sequence);
    try std.testing.expectEqual(@as(types.Drops, 1000 * types.XRP - 10), acct.balance);
}

test "RPC: submit TrustSet (34-byte minimal blob)" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const account = [_]u8{2} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 500 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 3,
    });

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    // Minimal TrustSet blob: tx_type=20, account (20), fee=10, sequence=3
    const blob = "00140202020202020202020202020202020202020202000000000000000A00000003";
    const result = try methods.submit(blob);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "tesSUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "TrustSet") != null);
    const acct = state.getAccount(account).?;
    try std.testing.expectEqual(@as(u32, 4), acct.sequence);
    try std.testing.expectEqual(@as(types.Drops, 500 * types.XRP - 10), acct.balance);
}

test "RPC: submit OfferCreate (50-byte minimal blob)" {
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
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 10,
    });

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    // OfferCreate: tx_type=7, account (20), fee=10, sequence=10, taker_pays=1000, taker_gets=2000
    const blob = "00070101010101010101010101010101010101010101000000000000000A0000000A00000000000003E800000000000007D0";
    const result = try methods.submit(blob);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "tesSUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "OfferCreate") != null);
    const acct = state.getAccount(account).?;
    try std.testing.expectEqual(@as(u32, 11), acct.sequence);
    try std.testing.expectEqual(@as(types.Drops, 1000 * types.XRP - 10), acct.balance);
}

test "RPC: submit OfferCancel (38-byte minimal blob)" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const account = [_]u8{3} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 500 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 4,
    });

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    // OfferCancel: tx_type=8, account (20), fee=10, sequence=4, offer_sequence=55
    const blob = "00080303030303030303030303030303030303030303000000000000000A0000000400000037";
    const result = try methods.submit(blob);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "tesSUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "OfferCancel") != null);
    const acct = state.getAccount(account).?;
    try std.testing.expectEqual(@as(u32, 5), acct.sequence);
    try std.testing.expectEqual(@as(types.Drops, 500 * types.XRP - 10), acct.balance);
}

test "RPC: submit EscrowCreate (34-byte minimal)" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();
    const account = [_]u8{4} ** 20;
    try state.putAccount(.{ .account = account, .balance = 1000 * types.XRP, .flags = .{}, .owner_count = 0, .previous_txn_id = [_]u8{0} ** 32, .previous_txn_lgr_seq = 1, .sequence = 6 });
    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);
    const blob = "00010404040404040404040404040404040404040404000000000000000A00000006";
    const result = try methods.submit(blob);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "tesSUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "escrow_create") != null);
}

test "RPC: submit CheckCreate (34-byte minimal)" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();
    const account = [_]u8{5} ** 20;
    try state.putAccount(.{ .account = account, .balance = 1000 * types.XRP, .flags = .{}, .owner_count = 0, .previous_txn_id = [_]u8{0} ** 32, .previous_txn_lgr_seq = 1, .sequence = 7 });
    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);
    const blob = "00100505050505050505050505050505050505050505000000000000000A00000007";
    const result = try methods.submit(blob);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "tesSUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "check_create") != null);
}

test "RPC: submit PaymentChannelCreate (34-byte minimal)" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();
    const account = [_]u8{6} ** 20;
    try state.putAccount(.{ .account = account, .balance = 1000 * types.XRP, .flags = .{}, .owner_count = 0, .previous_txn_id = [_]u8{0} ** 32, .previous_txn_lgr_seq = 1, .sequence = 8 });
    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);
    const blob = "000D0606060606060606060606060606060606060606000000000000000A00000008";
    const result = try methods.submit(blob);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "tesSUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "payment_channel_create") != null);
}

test "RPC: submit account_set with wrong blob length returns InvalidTxBlob" {
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
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 5,
    });

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    // AccountSet (type 3) with 62 bytes (payment length) - wrong for account_set
    const blob = "00030101010101010101010101010101010101010101000000000000000A00000005010101010101010101010101010101010101010101000000000000000A";
    const result = methods.submit(blob) catch |err| {
        try std.testing.expect(err == error.InvalidTxBlob);
        return;
    };
    allocator.free(result);
    try std.testing.expect(false); // Should have errored
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
