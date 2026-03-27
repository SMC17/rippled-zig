const std = @import("std");
const types = @import("types.zig");
const fee_engine = @import("fee_engine.zig");

/// Urgency level for fee prediction.
pub const Urgency = enum {
    /// Include in the very next ledger (~3-5 seconds)
    immediate,
    /// Include within ~3 ledgers (~10-15 seconds)
    normal,
    /// Include within ~10 ledgers (~30-50 seconds)
    low,
};

/// A single snapshot of ledger data used for feature extraction.
pub const LedgerSnapshot = struct {
    close_time: u64,
    tx_count: u32,
    avg_fee: types.Drops,
    queue_depth: u32,
};

/// Sliding window size for ledger history.
const WINDOW_SIZE = 64;

/// Minimum number of ledgers before the neural model activates.
const MIN_MODEL_HISTORY = 10;

/// Number of time-of-day buckets (4-hour buckets over 24 hours).
const TIME_BUCKETS = 6;

/// EWMA smoothing factor (alpha). Higher = more weight on recent observations.
const EWMA_ALPHA: f64 = 0.15;

// ── Neural network dimensions ──
const INPUT_DIM = 4;
const HIDDEN_DIM = 8;
const OUTPUT_DIM = 1;

/// Pre-trained (hand-tuned) weights for the feedforward model.
/// Layer 1: INPUT_DIM x HIDDEN_DIM weights + HIDDEN_DIM biases
/// Tuned based on XRPL fee dynamics:
///   input[0] = recent_avg_fee (normalized to [0,1] by dividing by 1000)
///   input[1] = queue_depth    (normalized to [0,1] by dividing by 300)
///   input[2] = fee_trend      (-1 falling, 0 stable, +1 rising)
///   input[3] = congestion_score (0..1)
const W1: [INPUT_DIM][HIDDEN_DIM]f64 = .{
    // recent_avg_fee connections — higher fees should push output up
    .{ 0.8, 0.3, -0.1, 0.5, 0.2, 0.1, 0.6, -0.2 },
    // queue_depth connections — deeper queue means higher fees
    .{ 0.5, 0.7, 0.4, 0.2, 0.8, 0.3, 0.1, 0.6 },
    // fee_trend connections — rising trend means fees will continue up
    .{ 0.3, 0.4, 0.6, 0.1, 0.2, 0.5, 0.3, 0.1 },
    // congestion_score connections — congestion demands higher fees
    .{ 0.6, 0.5, 0.3, 0.7, 0.4, 0.2, 0.8, 0.3 },
};

const B1: [HIDDEN_DIM]f64 = .{ -0.1, -0.2, -0.1, -0.15, -0.1, -0.05, -0.2, -0.1 };

/// Layer 2: HIDDEN_DIM x OUTPUT_DIM weights + OUTPUT_DIM bias
const W2: [HIDDEN_DIM][OUTPUT_DIM]f64 = .{
    .{0.35},
    .{0.25},
    .{0.15},
    .{0.20},
    .{0.30},
    .{0.10},
    .{0.25},
    .{0.15},
};

const B2: [OUTPUT_DIM]f64 = .{0.05};

/// ReLU activation.
fn relu(x: f64) f64 {
    return @max(0.0, x);
}

/// Feedforward pass: 4 inputs -> 8 hidden (ReLU) -> 1 output.
/// Returns a value roughly in [0, 1+] representing the fee multiplier above base.
fn feedforward(input: [INPUT_DIM]f64) f64 {
    // Hidden layer
    var hidden: [HIDDEN_DIM]f64 = undefined;
    for (0..HIDDEN_DIM) |j| {
        var sum: f64 = B1[j];
        for (0..INPUT_DIM) |i| {
            sum += input[i] * W1[i][j];
        }
        hidden[j] = relu(sum);
    }

    // Output layer (no activation — linear output)
    var output: f64 = B2[0];
    for (0..HIDDEN_DIM) |j| {
        output += hidden[j] * W2[j][0];
    }

    return output;
}

/// Adaptive fee estimator that learns from ledger history to predict optimal
/// transaction fees on the XRP Ledger.
pub const AdaptiveFeeEstimator = struct {
    /// Circular buffer of recent ledger snapshots.
    history: [WINDOW_SIZE]LedgerSnapshot,
    /// Number of snapshots currently stored (up to WINDOW_SIZE).
    count: u32,
    /// Write index into the circular buffer.
    write_idx: u32,

    /// Base fee in drops (floor for any estimate).
    base_fee: types.Drops,

    // ── EWMA state ──
    ewma_fee: f64,
    ewma_queue: f64,
    ewma_close_variance: f64,

    /// Previous average fee for trend detection.
    prev_avg_fee: f64,

    pub fn init(base_fee: types.Drops) AdaptiveFeeEstimator {
        return AdaptiveFeeEstimator{
            .history = [_]LedgerSnapshot{.{
                .close_time = 0,
                .tx_count = 0,
                .avg_fee = 0,
                .queue_depth = 0,
            }} ** WINDOW_SIZE,
            .count = 0,
            .write_idx = 0,
            .base_fee = base_fee,
            .ewma_fee = @floatFromInt(base_fee),
            .ewma_queue = 0.0,
            .ewma_close_variance = 0.0,
            .prev_avg_fee = @floatFromInt(base_fee),
        };
    }

    /// Ingest data from a closed ledger.
    pub fn updateFromLedger(
        self: *AdaptiveFeeEstimator,
        close_time: u64,
        tx_count: u32,
        avg_fee: types.Drops,
        queue_depth: u32,
    ) void {
        const snapshot = LedgerSnapshot{
            .close_time = close_time,
            .tx_count = tx_count,
            .avg_fee = avg_fee,
            .queue_depth = queue_depth,
        };
        self.history[self.write_idx] = snapshot;
        self.write_idx = (self.write_idx + 1) % WINDOW_SIZE;
        if (self.count < WINDOW_SIZE) {
            self.count += 1;
        }

        // Update EWMAs
        const fee_f: f64 = @floatFromInt(avg_fee);
        const queue_f: f64 = @floatFromInt(queue_depth);

        self.prev_avg_fee = self.ewma_fee;
        self.ewma_fee = EWMA_ALPHA * fee_f + (1.0 - EWMA_ALPHA) * self.ewma_fee;
        self.ewma_queue = EWMA_ALPHA * queue_f + (1.0 - EWMA_ALPHA) * self.ewma_queue;

        // Track close time variance (difference from expected ~4 second interval)
        if (self.count >= 2) {
            const prev_idx = if (self.write_idx == 0) WINDOW_SIZE - 1 else self.write_idx - 1;
            // The snapshot we just wrote is at write_idx-1 (since we incremented).
            // The one before it:
            const prev_prev_idx = if (prev_idx == 0) WINDOW_SIZE - 1 else prev_idx - 1;
            if (self.count >= 2) {
                const dt_raw = self.history[prev_idx].close_time -| self.history[prev_prev_idx].close_time;
                const dt: f64 = @floatFromInt(dt_raw);
                const deviation = @abs(dt - 4.0); // expected ~4 seconds
                self.ewma_close_variance = EWMA_ALPHA * deviation + (1.0 - EWMA_ALPHA) * self.ewma_close_variance;
            }
        }
    }

    // ── Feature extraction ──

    /// Fee trend: positive = rising, negative = falling, near-zero = stable.
    pub fn feeTrend(self: *const AdaptiveFeeEstimator) f64 {
        if (self.count < 2) return 0.0;
        const diff = self.ewma_fee - self.prev_avg_fee;
        // Clamp to [-1, 1]
        if (diff > 5.0) return 1.0;
        if (diff < -5.0) return -1.0;
        return diff / 5.0;
    }

    /// Congestion score from 0 (empty) to 100 (saturated).
    pub fn congestionScore(self: *const AdaptiveFeeEstimator) f64 {
        // Blend of queue depth and fee level
        const queue_component = @min(self.ewma_queue / 300.0, 1.0) * 60.0;
        const base_f: f64 = @floatFromInt(self.base_fee);
        const fee_ratio = @min(self.ewma_fee / (base_f * 10.0), 1.0);
        const fee_component = fee_ratio * 40.0;
        return @min(queue_component + fee_component, 100.0);
    }

    /// Volatility of recent fees (coefficient of variation).
    pub fn feeVolatility(self: *const AdaptiveFeeEstimator) f64 {
        if (self.count < 3) return 0.0;
        const n: usize = @intCast(self.count);
        var sum: f64 = 0.0;
        var sum_sq: f64 = 0.0;
        for (0..n) |i| {
            const f: f64 = @floatFromInt(self.history[i].avg_fee);
            sum += f;
            sum_sq += f * f;
        }
        const mean = sum / @as(f64, @floatFromInt(n));
        if (mean < 1.0) return 0.0;
        const variance = sum_sq / @as(f64, @floatFromInt(n)) - mean * mean;
        const stddev = @sqrt(@max(variance, 0.0));
        return stddev / mean;
    }

    /// Time-of-day bucket (0..5) derived from close_time.
    pub fn timeOfDayBucket(self: *const AdaptiveFeeEstimator) u32 {
        if (self.count == 0) return 0;
        const latest_idx = if (self.write_idx == 0) WINDOW_SIZE - 1 else self.write_idx - 1;
        const t = self.history[latest_idx].close_time;
        // XRPL epoch offset; extract hour-of-day and bucket into 4-hour chunks
        const seconds_in_day = t % 86400;
        const hour = seconds_in_day / 3600;
        return @intCast(hour / 4);
    }

    // ── Prediction ──

    /// Predict the optimal fee for a given urgency level.
    /// Returns fee in drops, guaranteed >= base_fee.
    pub fn predictOptimalFee(self: *const AdaptiveFeeEstimator, urgency: Urgency) types.Drops {
        // Cold start: use heuristic percentile-based estimation
        if (self.count < MIN_MODEL_HISTORY) {
            return self.heuristicFee(urgency);
        }

        // Prepare neural network inputs (normalized)
        const base_f: f64 = @floatFromInt(self.base_fee);
        const input = [INPUT_DIM]f64{
            @min(self.ewma_fee / 1000.0, 1.0), // normalized avg fee
            @min(self.ewma_queue / 300.0, 1.0), // normalized queue depth
            self.feeTrend(), // [-1, 1]
            self.congestionScore() / 100.0, // [0, 1]
        };

        const raw_output = feedforward(input);

        // Map output to fee: base_fee * (1 + output * scale_factor)
        // scale_factor varies by urgency
        const scale: f64 = switch (urgency) {
            .immediate => 20.0,
            .normal => 10.0,
            .low => 3.0,
        };

        const multiplier = 1.0 + @max(raw_output, 0.0) * scale;
        const predicted = base_f * multiplier;
        const clamped = @min(predicted, @as(f64, @floatFromInt(types.MAX_TX_FEE)));
        const result: u64 = @intFromFloat(@max(clamped, base_f));

        return @max(result, self.base_fee);
    }

    /// Heuristic fallback for cold start (< MIN_MODEL_HISTORY ledgers).
    /// Uses percentile of recent recorded fees.
    fn heuristicFee(self: *const AdaptiveFeeEstimator, urgency: Urgency) types.Drops {
        if (self.count == 0) {
            // No data at all: return base fee scaled by urgency
            return switch (urgency) {
                .immediate => self.base_fee * 3,
                .normal => self.base_fee * 2,
                .low => self.base_fee,
            };
        }

        // Collect and sort available fees
        const n: usize = @intCast(self.count);
        var fees: [WINDOW_SIZE]types.Drops = undefined;
        for (0..n) |i| {
            fees[i] = self.history[i].avg_fee;
        }
        std.mem.sort(types.Drops, fees[0..n], {}, std.sort.asc(types.Drops));

        // Select percentile based on urgency
        const idx: usize = switch (urgency) {
            .immediate => @min(n * 90 / 100, n - 1), // P90
            .normal => @min(n * 50 / 100, n - 1), // P50
            .low => @min(n * 25 / 100, n - 1), // P25
        };

        return @max(fees[idx], self.base_fee);
    }

    /// Confidence score in the current fee estimates.
    /// Returns a value between 0.0 (no confidence) and 1.0 (high confidence).
    pub fn confidence(self: *const AdaptiveFeeEstimator) f64 {
        if (self.count == 0) return 0.0;

        // Factor 1: amount of history (more data = more confidence)
        const history_factor = @min(@as(f64, @floatFromInt(self.count)) / @as(f64, WINDOW_SIZE), 1.0);

        // Factor 2: low volatility = higher confidence
        const vol = self.feeVolatility();
        const stability_factor = @max(1.0 - vol, 0.0);

        // Factor 3: close-time regularity (low variance = stable network)
        const regularity_factor = @max(1.0 - self.ewma_close_variance / 10.0, 0.0);

        // Weighted combination
        return @min(history_factor * 0.5 + stability_factor * 0.3 + regularity_factor * 0.2, 1.0);
    }

    /// Format a human-readable fee estimate report.
    pub fn report(self: *const AdaptiveFeeEstimator, writer: anytype) !void {
        try writer.print("=== AI Fee Estimation Report ===\n", .{});
        try writer.print("History:      {d}/{d} ledgers\n", .{ self.count, WINDOW_SIZE });
        try writer.print("EWMA fee:     {d:.1} drops\n", .{self.ewma_fee});
        try writer.print("EWMA queue:   {d:.1}\n", .{self.ewma_queue});
        try writer.print("Fee trend:    {d:.3}\n", .{self.feeTrend()});
        try writer.print("Congestion:   {d:.1}/100\n", .{self.congestionScore()});
        try writer.print("Volatility:   {d:.3}\n", .{self.feeVolatility()});
        try writer.print("Confidence:   {d:.2}\n", .{self.confidence()});
        try writer.print("\nRecommended fees:\n", .{});
        try writer.print("  Immediate:  {d} drops\n", .{self.predictOptimalFee(.immediate)});
        try writer.print("  Normal:     {d} drops\n", .{self.predictOptimalFee(.normal)});
        try writer.print("  Low:        {d} drops\n", .{self.predictOptimalFee(.low)});
        try writer.print("================================\n", .{});
    }
};

// ── CLI entry point for `rippled-zig fee-estimate` ──

pub fn cmdFeeEstimate() !void {
    const stdout = std.io.getStdOut().writer();

    var estimator = AdaptiveFeeEstimator.init(types.MIN_TX_FEE);

    // In a real node this would pull from live ledger data.
    // For demo purposes, show the cold-start estimator state.
    try stdout.print("rippled-zig AI Fee Estimator\n\n", .{});
    try stdout.print("Status: cold start (no live ledger feed)\n", .{});
    try stdout.print("Base fee: {d} drops\n\n", .{types.MIN_TX_FEE});

    // Simulate a few ledgers to demonstrate the engine
    const demo_data = [_]struct { ct: u64, tx: u32, fee: types.Drops, q: u32 }{
        .{ .ct = 1000, .tx = 50, .fee = 10, .q = 20 },
        .{ .ct = 1004, .tx = 80, .fee = 12, .q = 45 },
        .{ .ct = 1008, .tx = 120, .fee = 15, .q = 80 },
        .{ .ct = 1012, .tx = 200, .fee = 25, .q = 150 },
        .{ .ct = 1016, .tx = 180, .fee = 22, .q = 130 },
        .{ .ct = 1020, .tx = 100, .fee = 14, .q = 60 },
        .{ .ct = 1024, .tx = 90, .fee = 12, .q = 40 },
        .{ .ct = 1028, .tx = 70, .fee = 11, .q = 30 },
        .{ .ct = 1032, .tx = 60, .fee = 10, .q = 25 },
        .{ .ct = 1036, .tx = 55, .fee = 10, .q = 20 },
        .{ .ct = 1040, .tx = 75, .fee = 13, .q = 50 },
        .{ .ct = 1044, .tx = 110, .fee = 18, .q = 90 },
    };

    for (demo_data) |d| {
        estimator.updateFromLedger(d.ct, d.tx, d.fee, d.q);
    }

    try estimator.report(stdout);
}

// ── Tests ──

test "ai_fee: cold start uses heuristic (< 10 ledgers)" {
    var est = AdaptiveFeeEstimator.init(10);

    // Add fewer than MIN_MODEL_HISTORY ledgers
    est.updateFromLedger(100, 10, 12, 5);
    est.updateFromLedger(104, 15, 14, 10);
    est.updateFromLedger(108, 20, 18, 15);

    // Should still produce valid estimates (heuristic path)
    const fee_imm = est.predictOptimalFee(.immediate);
    const fee_norm = est.predictOptimalFee(.normal);
    const fee_low = est.predictOptimalFee(.low);

    try std.testing.expect(fee_imm >= 10);
    try std.testing.expect(fee_norm >= 10);
    try std.testing.expect(fee_low >= 10);

    // With only 3 data points, confidence should be low
    try std.testing.expect(est.confidence() < 0.5);
}

test "ai_fee: model produces reasonable fees after sufficient data" {
    var est = AdaptiveFeeEstimator.init(10);

    // Feed 15 ledgers of moderate activity
    for (0..15) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        est.updateFromLedger(t, 100, 15, 50);
    }

    const fee = est.predictOptimalFee(.normal);
    // Should be at least base fee and not astronomically high
    try std.testing.expect(fee >= 10);
    try std.testing.expect(fee <= 10_000);
}

test "ai_fee: immediate urgency > normal > low" {
    var est = AdaptiveFeeEstimator.init(10);

    // Feed enough data to activate the neural model
    for (0..20) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        // Moderate congestion
        est.updateFromLedger(t, 150, 20, 100);
    }

    const fee_imm = est.predictOptimalFee(.immediate);
    const fee_norm = est.predictOptimalFee(.normal);
    const fee_low = est.predictOptimalFee(.low);

    try std.testing.expect(fee_imm >= fee_norm);
    try std.testing.expect(fee_norm >= fee_low);
}

test "ai_fee: fee always >= base fee" {
    var est = AdaptiveFeeEstimator.init(10);

    // Even with zero-fee history, must return at least base_fee
    for (0..20) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        est.updateFromLedger(t, 5, 0, 0); // very low activity, zero avg_fee
    }

    try std.testing.expect(est.predictOptimalFee(.immediate) >= 10);
    try std.testing.expect(est.predictOptimalFee(.normal) >= 10);
    try std.testing.expect(est.predictOptimalFee(.low) >= 10);

    // Also check with zero history
    const fresh = AdaptiveFeeEstimator.init(10);
    try std.testing.expect(fresh.predictOptimalFee(.immediate) >= 10);
    try std.testing.expect(fresh.predictOptimalFee(.low) >= 10);
}

test "ai_fee: congestion detection increases fee estimates" {
    var est_calm = AdaptiveFeeEstimator.init(10);
    var est_busy = AdaptiveFeeEstimator.init(10);

    // Calm network
    for (0..20) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        est_calm.updateFromLedger(t, 30, 10, 10);
    }

    // Congested network
    for (0..20) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        est_busy.updateFromLedger(t, 250, 80, 250);
    }

    // Congested should recommend higher fees
    const calm_fee = est_calm.predictOptimalFee(.normal);
    const busy_fee = est_busy.predictOptimalFee(.normal);

    try std.testing.expect(busy_fee > calm_fee);

    // Congestion scores should reflect state
    try std.testing.expect(est_busy.congestionScore() > est_calm.congestionScore());
}

test "ai_fee: confidence increases with more data" {
    var est = AdaptiveFeeEstimator.init(10);

    const conf0 = est.confidence();

    // Add 5 ledgers
    for (0..5) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        est.updateFromLedger(t, 50, 12, 20);
    }
    const conf5 = est.confidence();

    // Add 20 more ledgers
    for (5..25) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        est.updateFromLedger(t, 50, 12, 20);
    }
    const conf25 = est.confidence();

    try std.testing.expect(conf5 > conf0);
    try std.testing.expect(conf25 > conf5);
}

test "ai_fee: feedforward network produces finite output" {
    // Verify the neural network doesn't produce NaN or Inf
    const input = [INPUT_DIM]f64{ 0.5, 0.3, 0.0, 0.2 };
    const output = feedforward(input);
    try std.testing.expect(!std.math.isNan(output));
    try std.testing.expect(!std.math.isInf(output));
    try std.testing.expect(output >= 0.0); // with ReLU hidden + positive weights, should be non-negative
}

test "ai_fee: EWMA tracks fee changes" {
    var est = AdaptiveFeeEstimator.init(10);

    // Feed low fees then high fees
    for (0..10) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        est.updateFromLedger(t, 50, 10, 10);
    }
    const ewma_low = est.ewma_fee;

    for (10..20) |i| {
        const t: u64 = 1000 + @as(u64, @intCast(i)) * 4;
        est.updateFromLedger(t, 200, 100, 200);
    }
    const ewma_high = est.ewma_fee;

    try std.testing.expect(ewma_high > ewma_low);
}
