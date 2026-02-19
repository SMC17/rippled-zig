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

/// Parallel validation using thread pool (read-only on state)
pub fn validateBatchParallel(
    allocator: std.mem.Allocator,
    processor: *const transaction.TransactionProcessor,
    state: *const ledger.AccountState,
    txs: []const types.Transaction,
) !void {
    if (txs.len <= 4) {
        return validateBatchSequential(processor, state, txs);
    }
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    for (txs, 0..) |_, i| {
        const p = processor;
        const s = state;
        const txs_ref = txs;
        const idx = i;
        pool.spawnWg(&pool, &wg, struct {
            fn validate(_p: *const transaction.TransactionProcessor, _s: *const ledger.AccountState, _txs: []const types.Transaction, _idx: usize) void {
                const tx_ref = &_txs[_idx];
                _ = _p.validateTransaction(tx_ref, _s) catch {};
            }
        }.validate, .{ p, s, txs_ref, idx });
    }
    wg.wait();
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
