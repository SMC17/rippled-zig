//! Parallel transaction processing exploration
//! Benchmarks and experiments for async/threading in validation/apply.

const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");
const transaction = @import("transaction.zig");

/// Validate a batch of transactions sequentially (baseline)
pub fn validateBatchSequential(
    processor: *const transaction.TransactionProcessor,
    state: *const ledger.AccountState,
    txs: []const types.Transaction,
) !void {
    for (txs) |*tx| {
        _ = processor.validateTransaction(tx, state) catch {};
    }
}

/// Placeholder for parallel validation (Zig async/thread pool)
/// rippled v2.3.0 claims parallel validation; this explores the pattern.
pub fn validateBatchParallel(
    allocator: std.mem.Allocator,
    processor: *const transaction.TransactionProcessor,
    state: *const ledger.AccountState,
    txs: []const types.Transaction,
) !void {
    _ = allocator;
    // TODO: Use std.Thread.Pool or async to parallelize validation
    validateBatchSequential(processor, state, txs);
}

test "validate batch sequential" {
    const allocator = std.testing.allocator;
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const acc = [_]u8{1} ** 20;
    try state.putAccount(.{
        .account = acc,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    const txs = [_]types.Transaction{
        .{ .tx_type = .account_set, .account = acc, .fee = types.MIN_TX_FEE, .sequence = 1 },
    };
    try validateBatchSequential(&processor, &state, &txs);
}
