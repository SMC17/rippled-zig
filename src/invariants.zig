//! Machine-checkable invariants for protocol correctness
//! Used in simulation harness and gate reports.
//! Can be enabled at comptime or runtime via build options.

const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");

pub const InvariantFailure = union(enum) {
    balance_conservation: struct {
        sum: types.Drops,
        fees_destroyed: types.Drops,
        expected: types.Drops,
    },
    sequence_monotonicity: struct {
        account_prefix: [8]u8,
        before_seq: u32,
        after_seq: u32,
    },
    ledger_sequence_monotonicity: struct {
        prev_seq: types.LedgerSequence,
        new_seq: types.LedgerSequence,
    },
    total_coins_within_bound: struct {
        total_coins: types.Drops,
        max_xrp: types.Drops,
    },
};

pub fn checkBalanceConservation(
    state: *const ledger.AccountState,
    total_fees_destroyed: types.Drops,
    expected_total: ?types.Drops,
) ?InvariantFailure {
    const sum = state.sumBalances();
    const expected = expected_total orelse types.MAX_XRP;
    const effective = sum +% total_fees_destroyed;
    if (effective != expected) {
        return .{ .balance_conservation = .{
            .sum = sum,
            .fees_destroyed = total_fees_destroyed,
            .expected = expected,
        } };
    }
    return null;
}

pub fn checkSequenceMonotonicity(
    before: *const ledger.AccountState,
    after: *const ledger.AccountState,
) ?InvariantFailure {
    var iter = after.accounts.iterator();
    while (iter.next()) |entry| {
        const after_id = entry.key_ptr.*;
        const after_acc = entry.value_ptr.*;
        if (before.getAccount(after_id)) |b| {
            if (after_acc.sequence < b.sequence) {
                var prefix: [8]u8 = [_]u8{0} ** 8;
                @memcpy(prefix[0..], after_id[0..8]);
                return .{ .sequence_monotonicity = .{
                    .account_prefix = prefix,
                    .before_seq = b.sequence,
                    .after_seq = after_acc.sequence,
                } };
            }
        }
    }
    return null;
}

pub fn checkLedgerSequenceMonotonicity(prev_seq: types.LedgerSequence, new_seq: types.LedgerSequence) ?InvariantFailure {
    if (new_seq <= prev_seq) {
        return .{ .ledger_sequence_monotonicity = .{
            .prev_seq = prev_seq,
            .new_seq = new_seq,
        } };
    }
    return null;
}

pub fn checkTotalCoinsWithinBound(ledger_obj: *const ledger.Ledger) ?InvariantFailure {
    if (ledger_obj.total_coins > types.MAX_XRP) {
        return .{ .total_coins_within_bound = .{
            .total_coins = ledger_obj.total_coins,
            .max_xrp = types.MAX_XRP,
        } };
    }
    return null;
}

/// Balance conservation: sum of all XRP balances + destroyed fees must equal constant.
/// Invariant: sum(balances) + fees_destroyed == expected_total
pub fn assertBalanceConservation(
    state: *const ledger.AccountState,
    total_fees_destroyed: types.Drops,
    expected_total: ?types.Drops,
) void {
    if (checkBalanceConservation(state, total_fees_destroyed, expected_total)) |failure| {
        const f = failure.balance_conservation;
        std.debug.panic("invariant violation: balance conservation: sum={d} fees_destroyed={d} expected={d}", .{
            f.sum,
            f.fees_destroyed,
            f.expected,
        });
    }
}

/// Sequence monotonicity: an account's sequence must never decrease.
/// Compares before/after snapshots. Use after applying a batch of transactions.
pub fn assertSequenceMonotonicity(
    before: *const ledger.AccountState,
    after: *const ledger.AccountState,
) void {
    if (checkSequenceMonotonicity(before, after)) |failure| {
        const f = failure.sequence_monotonicity;
        std.debug.panic("invariant violation: sequence monotonicity: account {any} seq {d} -> {d}", .{
            f.account_prefix,
            f.before_seq,
            f.after_seq,
        });
    }
}

/// Ledger sequence monotonicity: new ledger sequence must be > previous.
pub fn assertLedgerSequenceMonotonicity(prev_seq: types.LedgerSequence, new_seq: types.LedgerSequence) void {
    if (checkLedgerSequenceMonotonicity(prev_seq, new_seq)) |failure| {
        const f = failure.ledger_sequence_monotonicity;
        std.debug.panic("invariant violation: ledger sequence monotonicity: prev={d} new={d}", .{
            f.prev_seq,
            f.new_seq,
        });
    }
}

/// Total coins invariant: ledger total_coins must not exceed MAX_XRP.
pub fn assertTotalCoinsWithinBound(ledger_obj: *const ledger.Ledger) void {
    if (checkTotalCoinsWithinBound(ledger_obj)) |failure| {
        const f = failure.total_coins_within_bound;
        std.debug.panic("invariant violation: total_coins {d} > MAX_XRP", .{f.total_coins});
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

test "invariants violation reporting captures sequence monotonicity context" {
    const allocator = std.testing.allocator;
    var before = ledger.AccountState.init(allocator);
    defer before.deinit();
    var after = ledger.AccountState.init(allocator);
    defer after.deinit();

    const acc_id = [_]u8{7} ** 20;
    try before.putAccount(.{
        .account = acc_id,
        .balance = 100 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 9,
    });
    try after.putAccount(.{
        .account = acc_id,
        .balance = 100 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 8,
    });

    const failure = checkSequenceMonotonicity(&before, &after) orelse return error.ExpectedTestFailure;
    try std.testing.expectEqual(@as(u32, 9), failure.sequence_monotonicity.before_seq);
    try std.testing.expectEqual(@as(u32, 8), failure.sequence_monotonicity.after_seq);
}
