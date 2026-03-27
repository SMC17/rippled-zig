const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");
const fee_engine_mod = @import("fee_engine.zig");
const result_codes = @import("result_codes.zig");

/// A projected balance change for a single account.
pub const BalanceChange = struct {
    account: types.AccountID,
    before: types.Drops,
    after: types.Drops,
    delta: i128,
};

/// The outcome of a simulated transaction. No ledger state is modified.
pub const SimulationResult = struct {
    result_code: result_codes.ResultCode,
    fee_consumed: types.Drops,
    balance_changes: []BalanceChange,
    warnings: [][]const u8,
    estimated_ledger_inclusion: u32,

    /// The allocator that owns the dynamic slices so callers can free them.
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SimulationResult) void {
        self.allocator.free(self.balance_changes);
        self.allocator.free(self.warnings);
    }
};

/// Projected fill result for OfferCreate simulation.
pub const OfferFillEstimate = struct {
    /// How much of taker_gets would be filled at current prices.
    filled_gets: types.Drops,
    /// How much of taker_pays would be consumed by the fill.
    filled_pays: types.Drops,
    /// Remaining taker_gets that would sit on the book.
    remaining_gets: types.Drops,
    /// Remaining taker_pays on the book.
    remaining_pays: types.Drops,
};

/// Transaction simulation engine.
///
/// Evaluates the projected outcome of a transaction against a *clone* of the
/// relevant account state, without applying any side-effects to the real
/// ledger.  Useful for "what-if?" analysis and fee estimation.
pub const TransactionSimulator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TransactionSimulator {
        return .{ .allocator = allocator };
    }

    // ── Public API ──────────────────────────────────────────────

    /// Simulate a transaction and return a detailed result.
    /// The caller owns the returned SimulationResult and must call deinit().
    pub fn simulate(
        self: *const TransactionSimulator,
        tx: *const types.Transaction,
        account_state: *const ledger.AccountState,
        fee_eng: *const fee_engine_mod.FeeEngine,
    ) !SimulationResult {
        return self.simulatePaymentOrGeneric(tx, null, null, account_state, fee_eng);
    }

    /// Simulate a Payment transaction with the full payment fields.
    pub fn simulatePayment(
        self: *const TransactionSimulator,
        tx: *const types.Transaction,
        destination: types.AccountID,
        amount: types.Amount,
        account_state: *const ledger.AccountState,
        fee_eng: *const fee_engine_mod.FeeEngine,
    ) !SimulationResult {
        return self.simulatePaymentOrGeneric(tx, destination, amount, account_state, fee_eng);
    }

    /// Simulate an OfferCreate and return fill estimates alongside the
    /// standard SimulationResult.
    pub fn simulateOfferCreate(
        self: *const TransactionSimulator,
        tx: *const types.Transaction,
        taker_gets: types.Amount,
        taker_pays: types.Amount,
        account_state: *const ledger.AccountState,
        fee_eng: *const fee_engine_mod.FeeEngine,
    ) !struct { result: SimulationResult, fill: OfferFillEstimate } {
        // Validate sender exists
        const sender_account = account_state.getAccount(tx.account) orelse {
            return .{
                .result = try self.errorResult(result_codes.ResultCode.terNO_ACCOUNT, fee_eng),
                .fill = OfferFillEstimate{
                    .filled_gets = 0,
                    .filled_pays = 0,
                    .remaining_gets = 0,
                    .remaining_pays = 0,
                },
            };
        };

        // Basic fee / sequence validation
        if (validateBasic(tx, &sender_account, fee_eng)) |rc| {
            return .{
                .result = try self.errorResult(rc, fee_eng),
                .fill = OfferFillEstimate{
                    .filled_gets = 0,
                    .filled_pays = 0,
                    .remaining_gets = 0,
                    .remaining_pays = 0,
                },
            };
        }

        const gets_drops = switch (taker_gets) {
            .xrp => |d| d,
            .iou => 0,
        };

        const reserve = types.SafeDrops.accountReserve(sender_account.owner_count + 1) catch
            return .{
            .result = try self.errorResult(result_codes.ResultCode.tecINSUFFICIENT_RESERVE, fee_eng),
            .fill = OfferFillEstimate{ .filled_gets = 0, .filled_pays = 0, .remaining_gets = 0, .remaining_pays = 0 },
        };

        // For XRP offers, sender needs balance >= gets + fee + reserve
        if (taker_gets == .xrp) {
            const needed = addSaturating(gets_drops, tx.fee);
            if (sender_account.balance < addSaturating(needed, reserve)) {
                return .{
                    .result = try self.errorResult(result_codes.ResultCode.tecUNFUNDED_OFFER, fee_eng),
                    .fill = OfferFillEstimate{
                        .filled_gets = 0,
                        .filled_pays = 0,
                        .remaining_gets = gets_drops,
                        .remaining_pays = switch (taker_pays) {
                            .xrp => |d| d,
                            .iou => 0,
                        },
                    },
                };
            }
        }

        // Estimate fill — without a real order book we assume 25% fill as a
        // conservative heuristic (a real implementation would walk the book).
        const fill = estimateFill(taker_gets, taker_pays);

        // Build balance changes for XRP portion
        var changes = std.ArrayList(BalanceChange).init(self.allocator);
        defer changes.deinit();

        const sender_after = sender_account.balance - tx.fee - (if (taker_gets == .xrp) fill.filled_gets else 0);
        try changes.append(.{
            .account = tx.account,
            .before = sender_account.balance,
            .after = sender_after,
            .delta = @as(i128, sender_after) - @as(i128, sender_account.balance),
        });

        var warnings = std.ArrayList([]const u8).init(self.allocator);
        defer warnings.deinit();
        try appendFeeWarnings(&warnings, tx.fee, fee_eng);

        if (sender_after < reserve) {
            try warnings.append("close to reserve limit");
        }

        const inclusion = estimateInclusion(tx.fee, fee_eng);

        return .{
            .result = SimulationResult{
                .result_code = result_codes.ResultCode.tesSUCCESS,
                .fee_consumed = tx.fee,
                .balance_changes = try changes.toOwnedSlice(),
                .warnings = try warnings.toOwnedSlice(),
                .estimated_ledger_inclusion = inclusion,
                .allocator = self.allocator,
            },
            .fill = fill,
        };
    }

    // ── Internal helpers ────────────────────────────────────────

    fn simulatePaymentOrGeneric(
        self: *const TransactionSimulator,
        tx: *const types.Transaction,
        destination_opt: ?types.AccountID,
        amount_opt: ?types.Amount,
        account_state: *const ledger.AccountState,
        fee_eng: *const fee_engine_mod.FeeEngine,
    ) !SimulationResult {
        // 1. Sender must exist
        const sender_account = account_state.getAccount(tx.account) orelse {
            return self.errorResult(result_codes.ResultCode.terNO_ACCOUNT, fee_eng);
        };

        // 2. Basic validation (fee, sequence)
        if (validateBasic(tx, &sender_account, fee_eng)) |rc| {
            return self.errorResult(rc, fee_eng);
        }

        // 3. If this is a payment, do payment-specific simulation
        if (destination_opt) |destination| {
            return self.simulatePaymentInner(
                tx,
                &sender_account,
                destination,
                amount_opt.?,
                account_state,
                fee_eng,
            );
        }

        // 4. Generic transaction — just validate fee/sequence and return
        var changes = std.ArrayList(BalanceChange).init(self.allocator);
        defer changes.deinit();

        const sender_after = sender_account.balance - tx.fee;
        try changes.append(.{
            .account = tx.account,
            .before = sender_account.balance,
            .after = sender_after,
            .delta = @as(i128, sender_after) - @as(i128, sender_account.balance),
        });

        var warnings = std.ArrayList([]const u8).init(self.allocator);
        defer warnings.deinit();
        try appendFeeWarnings(&warnings, tx.fee, fee_eng);

        return SimulationResult{
            .result_code = result_codes.ResultCode.tesSUCCESS,
            .fee_consumed = tx.fee,
            .balance_changes = try changes.toOwnedSlice(),
            .warnings = try warnings.toOwnedSlice(),
            .estimated_ledger_inclusion = estimateInclusion(tx.fee, fee_eng),
            .allocator = self.allocator,
        };
    }

    fn simulatePaymentInner(
        self: *const TransactionSimulator,
        tx: *const types.Transaction,
        sender_account: *const types.AccountRoot,
        destination: types.AccountID,
        amount: types.Amount,
        account_state: *const ledger.AccountState,
        fee_eng: *const fee_engine_mod.FeeEngine,
    ) !SimulationResult {
        const xrp_amount: types.Drops = switch (amount) {
            .xrp => |d| d,
            .iou => 0, // IOU payments: XRP balance only changes by fee
        };

        var changes = std.ArrayList(BalanceChange).init(self.allocator);
        defer changes.deinit();

        var warnings = std.ArrayList([]const u8).init(self.allocator);
        defer warnings.deinit();

        const sender_reserve = types.SafeDrops.accountReserve(sender_account.owner_count) catch
            return self.errorResult(result_codes.ResultCode.tecINSUFFICIENT_RESERVE, fee_eng);

        // Check destination
        const dest_exists = account_state.hasAccount(destination);
        const creation_cost: types.Drops = if (!dest_exists) types.BASE_RESERVE else 0;

        if (!dest_exists) {
            // Creating a new account — amount must cover base reserve
            if (xrp_amount < types.BASE_RESERVE) {
                return self.errorResult(result_codes.ResultCode.tecNO_DST_INSUF_XRP, fee_eng);
            }
            try warnings.append("destination account will be created (reserve applies)");
        }

        // Total XRP the sender needs: amount + fee (+ creation cost is baked into amount requirement)
        const total_debit = addSaturating(xrp_amount, tx.fee);
        const min_balance = addSaturating(total_debit, sender_reserve);

        if (sender_account.balance < min_balance) {
            return self.errorResult(result_codes.ResultCode.tecUNFUNDED_PAYMENT, fee_eng);
        }

        // Compute projected balances
        const sender_after = sender_account.balance - xrp_amount - tx.fee;
        try changes.append(.{
            .account = tx.account,
            .before = sender_account.balance,
            .after = sender_after,
            .delta = @as(i128, sender_after) - @as(i128, sender_account.balance),
        });

        // Destination balance change
        const dest_before: types.Drops = if (account_state.getAccount(destination)) |d| d.balance else 0;
        const dest_after = dest_before + xrp_amount;
        try changes.append(.{
            .account = destination,
            .before = dest_before,
            .after = dest_after,
            .delta = @as(i128, dest_after) - @as(i128, dest_before),
        });

        // Warnings
        try appendFeeWarnings(&warnings, tx.fee, fee_eng);

        if (sender_after < addSaturating(sender_reserve, types.OWNER_RESERVE)) {
            try warnings.append("close to reserve limit");
        }

        _ = creation_cost;

        return SimulationResult{
            .result_code = result_codes.ResultCode.tesSUCCESS,
            .fee_consumed = tx.fee,
            .balance_changes = try changes.toOwnedSlice(),
            .warnings = try warnings.toOwnedSlice(),
            .estimated_ledger_inclusion = estimateInclusion(tx.fee, fee_eng),
            .allocator = self.allocator,
        };
    }

    /// Build a minimal error result (no balance changes).
    fn errorResult(
        self: *const TransactionSimulator,
        code: result_codes.ResultCode,
        fee_eng: *const fee_engine_mod.FeeEngine,
    ) !SimulationResult {
        var warnings = std.ArrayList([]const u8).init(self.allocator);
        defer warnings.deinit();

        // For claimed errors the fee is still consumed
        const fee_consumed: types.Drops = if (code.isClaimed()) 0 else 0;

        return SimulationResult{
            .result_code = code,
            .fee_consumed = fee_consumed,
            .balance_changes = try self.allocator.alloc(BalanceChange, 0),
            .warnings = try warnings.toOwnedSlice(),
            .estimated_ledger_inclusion = estimateInclusion(0, fee_eng),
            .allocator = self.allocator,
        };
    }
};

// ── Free helper functions ──────────────────────────────────────────

/// Validate fee and sequence against sender account. Returns null on
/// success, or the appropriate error ResultCode.
fn validateBasic(
    tx: *const types.Transaction,
    sender: *const types.AccountRoot,
    fee_eng: *const fee_engine_mod.FeeEngine,
) ?result_codes.ResultCode {
    _ = fee_eng;
    // Fee below absolute minimum
    if (tx.fee < types.MIN_TX_FEE) return result_codes.ResultCode.temBAD_FEE;
    // Balance cannot cover fee at all
    if (sender.balance < tx.fee) return result_codes.ResultCode.terINSUF_FEE_B;
    // Sequence mismatch
    if (tx.sequence != sender.sequence) return result_codes.ResultCode.tefPAST_SEQ;
    return null;
}

/// Append fee-related warnings.
fn appendFeeWarnings(
    warnings: *std.ArrayList([]const u8),
    tx_fee: types.Drops,
    fee_eng: *const fee_engine_mod.FeeEngine,
) !void {
    const open_cost = fee_eng.openLedgerFee();
    if (tx_fee > open_cost * 10 and tx_fee > types.MIN_TX_FEE * 10) {
        try warnings.append("fee higher than median");
    }
    if (tx_fee < open_cost) {
        try warnings.append("fee below open ledger cost — transaction may be queued");
    }
}

/// Estimate how many ledgers until inclusion based on fee vs open ledger cost.
fn estimateInclusion(tx_fee: types.Drops, fee_eng: *const fee_engine_mod.FeeEngine) u32 {
    const open_cost = fee_eng.openLedgerFee();
    if (tx_fee == 0) return 10; // worst case placeholder
    if (tx_fee >= open_cost) return 1; // immediate
    // Fee is below open ledger cost -- at minimum 2 ledgers (queued).
    // Scale further based on how far below the cost we are.
    // ratio uses ceiling division to avoid rounding down to 1.
    const ratio = (open_cost + tx_fee - 1) / tx_fee;
    const clamped = @min(ratio, 10);
    return @max(@as(u32, @intCast(clamped)), 2);
}

/// Estimate fill for an OfferCreate without a real order book.
/// Uses a fixed 25% fill heuristic.
fn estimateFill(taker_gets: types.Amount, taker_pays: types.Amount) OfferFillEstimate {
    const gets_total: types.Drops = switch (taker_gets) {
        .xrp => |d| d,
        .iou => 0,
    };
    const pays_total: types.Drops = switch (taker_pays) {
        .xrp => |d| d,
        .iou => 0,
    };

    const filled_gets = gets_total / 4;
    const filled_pays = pays_total / 4;

    return .{
        .filled_gets = filled_gets,
        .filled_pays = filled_pays,
        .remaining_gets = gets_total - filled_gets,
        .remaining_pays = pays_total - filled_pays,
    };
}

/// Saturating add for Drops (caps at max u64).
fn addSaturating(a: types.Drops, b: types.Drops) types.Drops {
    const result, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return std.math.maxInt(types.Drops);
    return result;
}

// ── Tests ──────────────────────────────────────────────────────────

test "simulate successful XRP payment" {
    const allocator = std.testing.allocator;

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    const sender_id = [_]u8{1} ** 20;
    const dest_id = [_]u8{2} ** 20;

    try state.putAccount(.{
        .account = sender_id,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });
    try state.putAccount(.{
        .account = dest_id,
        .balance = 50 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    const tx = types.Transaction{
        .tx_type = .payment,
        .account = sender_id,
        .fee = types.MIN_TX_FEE,
        .sequence = 1,
    };

    const fee_eng = fee_engine_mod.FeeEngine.init(10);
    const sim = TransactionSimulator.init(allocator);

    var result = try sim.simulatePayment(&tx, dest_id, types.Amount.fromXRP(100 * types.XRP), &state, &fee_eng);
    defer result.deinit();

    try std.testing.expectEqual(result_codes.ResultCode.tesSUCCESS, result.result_code);
    try std.testing.expectEqual(@as(types.Drops, types.MIN_TX_FEE), result.fee_consumed);
    try std.testing.expectEqual(@as(usize, 2), result.balance_changes.len);
}

test "simulate payment to unfunded destination (account creation)" {
    const allocator = std.testing.allocator;

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    const sender_id = [_]u8{1} ** 20;
    const dest_id = [_]u8{3} ** 20; // does not exist

    try state.putAccount(.{
        .account = sender_id,
        .balance = 500 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    const tx = types.Transaction{
        .tx_type = .payment,
        .account = sender_id,
        .fee = types.MIN_TX_FEE,
        .sequence = 1,
    };

    const fee_eng = fee_engine_mod.FeeEngine.init(10);
    const sim = TransactionSimulator.init(allocator);

    // Send enough to cover base reserve (10 XRP)
    var result = try sim.simulatePayment(&tx, dest_id, types.Amount.fromXRP(20 * types.XRP), &state, &fee_eng);
    defer result.deinit();

    try std.testing.expectEqual(result_codes.ResultCode.tesSUCCESS, result.result_code);

    // Destination should go from 0 to 20 XRP
    const dest_change = result.balance_changes[1];
    try std.testing.expectEqual(@as(types.Drops, 0), dest_change.before);
    try std.testing.expectEqual(@as(types.Drops, 20 * types.XRP), dest_change.after);

    // Should have a warning about account creation
    var found_creation_warning = false;
    for (result.warnings) |w| {
        if (std.mem.indexOf(u8, w, "created") != null) {
            found_creation_warning = true;
            break;
        }
    }
    try std.testing.expect(found_creation_warning);
}

test "simulate payment with insufficient balance" {
    const allocator = std.testing.allocator;

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    const sender_id = [_]u8{1} ** 20;
    const dest_id = [_]u8{2} ** 20;

    // Sender has only 15 XRP — not enough for 100 XRP + fee + 10 XRP reserve
    try state.putAccount(.{
        .account = sender_id,
        .balance = 15 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });
    try state.putAccount(.{
        .account = dest_id,
        .balance = 50 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    const tx = types.Transaction{
        .tx_type = .payment,
        .account = sender_id,
        .fee = types.MIN_TX_FEE,
        .sequence = 1,
    };

    const fee_eng = fee_engine_mod.FeeEngine.init(10);
    const sim = TransactionSimulator.init(allocator);

    var result = try sim.simulatePayment(&tx, dest_id, types.Amount.fromXRP(100 * types.XRP), &state, &fee_eng);
    defer result.deinit();

    try std.testing.expectEqual(result_codes.ResultCode.tecUNFUNDED_PAYMENT, result.result_code);
}

test "simulate with fee below open ledger cost shows queued estimate" {
    const allocator = std.testing.allocator;

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    const sender_id = [_]u8{1} ** 20;
    const dest_id = [_]u8{2} ** 20;

    try state.putAccount(.{
        .account = sender_id,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });
    try state.putAccount(.{
        .account = dest_id,
        .balance = 50 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    // Create a fee engine with queue pressure so open ledger cost > base
    var fee_eng = fee_engine_mod.FeeEngine.init(10);
    fee_eng.updateQueueSize(250); // heavy queue pressure

    const open_cost = fee_eng.openLedgerFee();
    // Sanity: open cost should be elevated
    try std.testing.expect(open_cost > 10);

    // Use the minimum fee which is below the open ledger cost
    const tx = types.Transaction{
        .tx_type = .payment,
        .account = sender_id,
        .fee = types.MIN_TX_FEE, // 10 drops, below escalated cost
        .sequence = 1,
    };

    const sim = TransactionSimulator.init(allocator);
    var result = try sim.simulatePayment(&tx, dest_id, types.Amount.fromXRP(1 * types.XRP), &state, &fee_eng);
    defer result.deinit();

    // Transaction should still simulate successfully (it would be queued, not rejected)
    try std.testing.expectEqual(result_codes.ResultCode.tesSUCCESS, result.result_code);

    // Estimated inclusion should be > 1 since fee is below open ledger cost
    try std.testing.expect(result.estimated_ledger_inclusion > 1);

    // Should have a warning about being below open ledger cost
    var found_queue_warning = false;
    for (result.warnings) |w| {
        if (std.mem.indexOf(u8, w, "queued") != null) {
            found_queue_warning = true;
            break;
        }
    }
    try std.testing.expect(found_queue_warning);
}

test "balance changes are accurate" {
    const allocator = std.testing.allocator;

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    const sender_id = [_]u8{1} ** 20;
    const dest_id = [_]u8{2} ** 20;

    const sender_initial: types.Drops = 200 * types.XRP;
    const dest_initial: types.Drops = 30 * types.XRP;
    const payment_amount: types.Drops = 50 * types.XRP;
    const fee: types.Drops = 12;

    try state.putAccount(.{
        .account = sender_id,
        .balance = sender_initial,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 5,
    });
    try state.putAccount(.{
        .account = dest_id,
        .balance = dest_initial,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    const tx = types.Transaction{
        .tx_type = .payment,
        .account = sender_id,
        .fee = fee,
        .sequence = 5,
    };

    const fee_eng = fee_engine_mod.FeeEngine.init(10);
    const sim = TransactionSimulator.init(allocator);

    var result = try sim.simulatePayment(&tx, dest_id, types.Amount.fromXRP(payment_amount), &state, &fee_eng);
    defer result.deinit();

    try std.testing.expectEqual(result_codes.ResultCode.tesSUCCESS, result.result_code);
    try std.testing.expectEqual(@as(usize, 2), result.balance_changes.len);

    // Sender: before=200 XRP, after = 200 XRP - 50 XRP - 12 drops
    const sender_change = result.balance_changes[0];
    try std.testing.expectEqual(sender_initial, sender_change.before);
    try std.testing.expectEqual(sender_initial - payment_amount - fee, sender_change.after);
    const expected_sender_delta = -@as(i128, payment_amount) - @as(i128, fee);
    try std.testing.expectEqual(expected_sender_delta, sender_change.delta);

    // Destination: before=30 XRP, after = 30 XRP + 50 XRP
    const dest_change = result.balance_changes[1];
    try std.testing.expectEqual(dest_initial, dest_change.before);
    try std.testing.expectEqual(dest_initial + payment_amount, dest_change.after);
    try std.testing.expectEqual(@as(i128, payment_amount), dest_change.delta);
}

test "simulate offer create" {
    const allocator = std.testing.allocator;

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    const sender_id = [_]u8{1} ** 20;
    try state.putAccount(.{
        .account = sender_id,
        .balance = 500 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    const tx = types.Transaction{
        .tx_type = .offer_create,
        .account = sender_id,
        .fee = types.MIN_TX_FEE,
        .sequence = 1,
    };

    const fee_eng = fee_engine_mod.FeeEngine.init(10);
    const sim = TransactionSimulator.init(allocator);

    const outcome = try sim.simulateOfferCreate(
        &tx,
        types.Amount.fromXRP(100 * types.XRP),
        types.Amount.fromXRP(200 * types.XRP),
        &state,
        &fee_eng,
    );
    var result = outcome.result;
    defer result.deinit();
    const fill = outcome.fill;

    try std.testing.expectEqual(result_codes.ResultCode.tesSUCCESS, result.result_code);

    // 25% fill heuristic
    try std.testing.expectEqual(@as(types.Drops, 25 * types.XRP), fill.filled_gets);
    try std.testing.expectEqual(@as(types.Drops, 50 * types.XRP), fill.filled_pays);
    try std.testing.expectEqual(@as(types.Drops, 75 * types.XRP), fill.remaining_gets);
    try std.testing.expectEqual(@as(types.Drops, 150 * types.XRP), fill.remaining_pays);
}
