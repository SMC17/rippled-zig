const std = @import("std");
const types = @import("types.zig");

/// XRPL Fee Escalation Engine
///
/// The XRP Ledger uses a dynamic fee mechanism:
/// - Base fee: minimum fee for a transaction (currently 10 drops)
/// - Open ledger cost: escalates when the transaction queue fills
/// - Formula: escalated_fee = base_fee * (queue_size / max_queue_size + 1) ^ 2
///
/// This ensures that during high traffic, users can prioritize their
/// transactions by paying higher fees, while normal traffic pays base fee.
pub const FeeEngine = struct {
    /// Current base fee in drops (typically 10)
    base_fee: types.Drops,

    /// Maximum transactions per ledger before escalation kicks in
    max_queue_size: u32,

    /// Current number of transactions in the open ledger queue
    current_queue_size: u32,

    /// Reference fee unit (used for reserve calculations)
    reference_fee_units: u64,

    /// Load multiplier — increases under sustained load
    load_factor: u32,

    /// Normal load factor (denominator)
    load_base: u32,

    /// Fee escalation history for adaptive estimation
    recent_fees: [16]types.Drops,
    recent_fee_count: u8,
    recent_fee_idx: u8,

    pub fn init(base_fee: types.Drops) FeeEngine {
        return FeeEngine{
            .base_fee = base_fee,
            .max_queue_size = 300, // typical XRPL ledger capacity
            .current_queue_size = 0,
            .reference_fee_units = 10,
            .load_factor = 256,
            .load_base = 256,
            .recent_fees = [_]types.Drops{0} ** 16,
            .recent_fee_count = 0,
            .recent_fee_idx = 0,
        };
    }

    /// Calculate the minimum fee required for a transaction to be included
    /// in the next open ledger, accounting for queue pressure.
    pub fn openLedgerFee(self: *const FeeEngine) types.Drops {
        if (self.current_queue_size <= self.max_queue_size / 2) {
            return self.scaledFee();
        }

        // Quadratic escalation when queue is > 50% full
        const queue_ratio = @as(u64, self.current_queue_size) * 256 / @as(u64, self.max_queue_size);
        const multiplier = (queue_ratio * queue_ratio) / 256;
        const escalated = self.scaledFee() * (multiplier + 256) / 256;

        return @max(escalated, self.scaledFee());
    }

    /// Fee with load factor applied
    pub fn scaledFee(self: *const FeeEngine) types.Drops {
        return self.base_fee * @as(u64, self.load_factor) / @as(u64, self.load_base);
    }

    /// Estimate the fee needed for a transaction to be included within
    /// N ledgers, based on recent fee history.
    pub fn estimateFee(self: *const FeeEngine, target_ledgers: u32) types.Drops {
        if (target_ledgers == 0 or self.recent_fee_count == 0) {
            return self.openLedgerFee();
        }

        // For immediate inclusion (1 ledger), return open ledger fee
        if (target_ledgers <= 1) {
            return self.openLedgerFee();
        }

        // For deferred inclusion, use median of recent fees
        var sorted: [16]types.Drops = undefined;
        const count = @as(usize, self.recent_fee_count);
        @memcpy(sorted[0..count], self.recent_fees[0..count]);
        std.mem.sort(types.Drops, sorted[0..count], {}, std.sort.asc(types.Drops));

        const median = sorted[count / 2];

        // Scale down for longer target horizons
        if (target_ledgers >= 5) {
            return @max(median / 2, self.base_fee);
        }
        return @max(median, self.base_fee);
    }

    /// Record a fee that was accepted in a recently closed ledger.
    /// Used for adaptive fee estimation.
    pub fn recordAcceptedFee(self: *FeeEngine, fee: types.Drops) void {
        self.recent_fees[self.recent_fee_idx] = fee;
        self.recent_fee_idx = (self.recent_fee_idx + 1) % 16;
        if (self.recent_fee_count < 16) {
            self.recent_fee_count += 1;
        }
    }

    /// Update queue state when transactions are added/removed
    pub fn updateQueueSize(self: *FeeEngine, new_size: u32) void {
        self.current_queue_size = new_size;
    }

    /// Update load factor (called by consensus/network layer)
    pub fn updateLoadFactor(self: *FeeEngine, factor: u32) void {
        self.load_factor = @max(factor, self.load_base); // never below base
    }

    /// Reset load factor to normal
    pub fn resetLoad(self: *FeeEngine) void {
        self.load_factor = self.load_base;
    }

    /// Validate that a transaction's fee is sufficient
    pub fn validateFee(self: *const FeeEngine, tx_fee: types.Drops) FeeValidation {
        if (tx_fee < self.base_fee) return .below_minimum;
        if (tx_fee < self.openLedgerFee()) return .below_open_ledger;
        if (tx_fee > types.MAX_TX_FEE) return .suspiciously_high;
        return .acceptable;
    }

    pub const FeeValidation = enum {
        acceptable,
        below_minimum,
        below_open_ledger,
        suspiciously_high,
    };
};

// ── Tests ──

test "fee engine: base fee with no load" {
    const engine = FeeEngine.init(10);
    try std.testing.expectEqual(@as(types.Drops, 10), engine.openLedgerFee());
    try std.testing.expectEqual(@as(types.Drops, 10), engine.scaledFee());
}

test "fee engine: escalation under queue pressure" {
    var engine = FeeEngine.init(10);
    engine.updateQueueSize(200); // 200/300 = 67% full
    const fee = engine.openLedgerFee();
    // Should be higher than base fee due to quadratic escalation
    try std.testing.expect(fee > 10);
    std.debug.print("[PASS] Fee escalation: {d} drops at 67% queue\n", .{fee});
}

test "fee engine: full queue escalation" {
    var engine = FeeEngine.init(10);
    engine.updateQueueSize(300); // 100% full
    const fee = engine.openLedgerFee();
    try std.testing.expect(fee >= 20); // significant escalation
    std.debug.print("[PASS] Full queue fee: {d} drops\n", .{fee});
}

test "fee engine: load factor" {
    var engine = FeeEngine.init(10);
    engine.updateLoadFactor(512); // 2x load
    try std.testing.expectEqual(@as(types.Drops, 20), engine.scaledFee());
}

test "fee engine: fee validation" {
    const engine = FeeEngine.init(10);
    try std.testing.expectEqual(FeeEngine.FeeValidation.below_minimum, engine.validateFee(5));
    try std.testing.expectEqual(FeeEngine.FeeValidation.acceptable, engine.validateFee(10));
    try std.testing.expectEqual(FeeEngine.FeeValidation.acceptable, engine.validateFee(100));
    try std.testing.expectEqual(FeeEngine.FeeValidation.suspiciously_high, engine.validateFee(2_000_000));
}

test "fee engine: adaptive estimation with history" {
    var engine = FeeEngine.init(10);

    // Record some recent fees
    engine.recordAcceptedFee(12);
    engine.recordAcceptedFee(15);
    engine.recordAcceptedFee(11);
    engine.recordAcceptedFee(20);
    engine.recordAcceptedFee(13);

    // Immediate: use open ledger fee
    const immediate = engine.estimateFee(1);
    try std.testing.expectEqual(@as(types.Drops, 10), immediate);

    // 3-ledger target: use median of recent
    const deferred = engine.estimateFee(3);
    try std.testing.expect(deferred >= 10);

    std.debug.print("[PASS] Adaptive fee estimation: immediate={d}, deferred={d}\n", .{ immediate, deferred });
}

test "fee engine: never below base" {
    var engine = FeeEngine.init(10);
    engine.updateLoadFactor(128); // 0.5x — but should clamp to base
    try std.testing.expect(engine.scaledFee() >= 10);
}
