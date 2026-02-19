//! Machine-checkable invariants for protocol correctness
//! Used in simulation harness and gate reports.
//! Can be enabled at comptime or runtime via build options.

const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");

/// Balance conservation: sum of all XRP balances + destroyed fees must equal constant.
/// Invariant: sum(balances) + fees_destroyed == expected_total
pub fn assertBalanceConservation(
    state: *const ledger.AccountState,
    total_fees_destroyed: types.Drops,
    expected_total: ?types.Drops,
) void {
    const sum = state.sumBalances();
    const expected = expected_total orelse types.MAX_XRP;
    const effective = sum +% total_fees_destroyed;
    if (effective != expected) {
        std.debug.panic("invariant violation: balance conservation: sum={d} fees_destroyed={d} expected={d}", .{
            sum,
            total_fees_destroyed,
            expected,
        });
    }
}

fn checkSequenceMonotonicity(
    before: *const ledger.AccountState,
    after_id: types.AccountID,
    after_acc: types.AccountRoot,
) void {
    if (before.getAccount(after_id)) |b| {
        if (after_acc.sequence < b.sequence) {
            std.debug.panic("invariant violation: sequence monotonicity: account {any} seq {d} -> {d}", .{
                after_id[0..8],
                b.sequence,
                after_acc.sequence,
            });
        }
    }
}

/// Sequence monotonicity: an account's sequence must never decrease.
/// Compares before/after snapshots. Use after applying a batch of transactions.
pub fn assertSequenceMonotonicity(
    before: *const ledger.AccountState,
    after: *const ledger.AccountState,
) void {
    after.forEach(before, checkSequenceMonotonicity);
}

/// Ledger sequence monotonicity: new ledger sequence must be > previous.
pub fn assertLedgerSequenceMonotonicity(prev_seq: types.LedgerSequence, new_seq: types.LedgerSequence) void {
    if (new_seq <= prev_seq) {
        std.debug.panic("invariant violation: ledger sequence monotonicity: prev={d} new={d}", .{
            prev_seq,
            new_seq,
        });
    }
}

/// Total coins invariant: ledger total_coins must not exceed MAX_XRP.
pub fn assertTotalCoinsWithinBound(ledger_obj: *const ledger.Ledger) void {
    if (ledger_obj.total_coins > types.MAX_XRP) {
        std.debug.panic("invariant violation: total_coins {d} > MAX_XRP", .{ledger_obj.total_coins});
    }
}

test "invariants balance conservation trivial" {
    const allocator = std.testing.allocator;
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    const acc_id = [_]u8{1} ** 20;
    try state.putAccount(.{
        .account = acc_id,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    // Sum = 1000 XRP, fees_destroyed = 0, expected = 1000 XRP (not MAX - we're checking local state)
    // For local state without genesis, we just verify no panic for reasonable inputs
    assertBalanceConservation(&state, 0, 1000 * types.XRP);
}

test "invariants sequence monotonicity" {
    const allocator = std.testing.allocator;
    var before = ledger.AccountState.init(allocator);
    defer before.deinit();
    var after = ledger.AccountState.init(allocator);
    defer after.deinit();

    const acc_id = [_]u8{1} ** 20;
    try before.putAccount(.{
        .account = acc_id,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 5,
    });
    try after.putAccount(.{
        .account = acc_id,
        .balance = 999 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 6,
    });

    assertSequenceMonotonicity(&before, &after);
}
