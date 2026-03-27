const std = @import("std");
const types = @import("types.zig");
const dex = @import("dex.zig");

const AccountID = types.AccountID;
const CurrencyCode = types.CurrencyCode;
const Amount = types.Amount;

// ---------------------------------------------------------------------------
// Asset — a currency + issuer pair identifying one side of an AMM pool
// ---------------------------------------------------------------------------

pub const Asset = struct {
    currency: CurrencyCode,
    issuer: AccountID,

    pub fn eql(self: Asset, other: Asset) bool {
        return std.mem.eql(u8, &self.currency.bytes, &other.currency.bytes) and
            std.mem.eql(u8, &self.issuer, &other.issuer);
    }
};

// ---------------------------------------------------------------------------
// AuctionSlot — 24-hour continuous auction for discounted trading
// ---------------------------------------------------------------------------

pub const AuctionSlot = struct {
    /// Account that currently holds the auction slot.
    account: AccountID,
    /// Price paid (in LP tokens) for the slot.
    price: u64,
    /// Expiration timestamp (XRPL epoch seconds).
    expiration: u64,
    /// Discount in basis points the slot holder receives (max = trading_fee).
    discount_bps: u16,
};

// ---------------------------------------------------------------------------
// FeeVote — a single LP holder's vote on the trading fee
// ---------------------------------------------------------------------------

pub const FeeVote = struct {
    account: AccountID,
    /// The fee this LP holder votes for (0-1000 basis points).
    fee_bps: u16,
    /// Number of LP tokens held by this voter (weight).
    lp_tokens: u64,
};

// ---------------------------------------------------------------------------
// AMMPool — represents an XLS-30 Automated Market Maker liquidity pool
// ---------------------------------------------------------------------------

pub const AMMPool = struct {
    asset1: Asset,
    asset2: Asset,
    balance1: u64,
    balance2: u64,
    /// Total LP tokens outstanding.
    lp_token_supply: u64,
    /// Trading fee in basis points (0-1000, i.e. 0% to 1%).
    trading_fee: u16,
    /// Optional 24-hour continuous auction slot for discounted trading.
    auction_slot: ?AuctionSlot,
    /// Fee votes from LP holders.
    fee_votes: std.ArrayList(FeeVote),

    /// Maximum allowed trading fee: 1000 basis points = 1%.
    pub const MAX_TRADING_FEE: u16 = 1000;
    /// Basis-point denominator.
    pub const BPS_DENOM: u64 = 10_000;

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /// Create a new AMM pool with an initial two-asset deposit.
    /// The initial depositor receives LP tokens equal to
    /// sqrt(amount1 * amount2) (geometric mean).
    pub fn init(
        allocator: std.mem.Allocator,
        asset1: Asset,
        asset2: Asset,
        amount1: u64,
        amount2: u64,
        fee_bps: u16,
    ) error{ ZeroDeposit, FeeTooHigh }!AMMPool {
        if (amount1 == 0 or amount2 == 0) return error.ZeroDeposit;
        if (fee_bps > MAX_TRADING_FEE) return error.FeeTooHigh;

        // LP tokens = sqrt(amount1 * amount2) using u128 to avoid overflow.
        const product: u128 = @as(u128, amount1) * @as(u128, amount2);
        const lp_tokens: u64 = @intCast(std.math.sqrt(product));

        return AMMPool{
            .asset1 = asset1,
            .asset2 = asset2,
            .balance1 = amount1,
            .balance2 = amount2,
            .lp_token_supply = lp_tokens,
            .trading_fee = fee_bps,
            .auction_slot = null,
            .fee_votes = std.ArrayList(FeeVote).init(allocator),
        };
    }

    pub fn deinit(self: *AMMPool) void {
        self.fee_votes.deinit();
    }

    // ------------------------------------------------------------------
    // Constant-product swap: x * y = k
    // ------------------------------------------------------------------

    /// Which asset the caller is providing.
    pub const SwapAsset = enum { asset1, asset2 };

    pub const SwapResult = struct {
        output_amount: u64,
        /// The effective input after the fee was deducted.
        effective_input: u64,
        fee_deducted: u64,
    };

    /// Swap `input_amount` of one asset for the other.
    /// Applies the trading fee before computing the constant-product output.
    ///
    /// Formula:
    ///   effective_input = input_amount * (BPS_DENOM - trading_fee) / BPS_DENOM
    ///   output = (balance_out * effective_input) / (balance_in + effective_input)
    ///
    /// The pool balances are updated in place.
    pub fn swap(self: *AMMPool, side: SwapAsset, input_amount: u64) error{ ZeroInput, InsufficientLiquidity }!SwapResult {
        if (input_amount == 0) return error.ZeroInput;

        const fee_factor: u64 = BPS_DENOM - @as(u64, self.trading_fee);
        // Use u128 for intermediate calculations to avoid overflow.
        const effective_input: u64 = @intCast((@as(u128, input_amount) * fee_factor) / BPS_DENOM);
        const fee_deducted = input_amount - effective_input;

        const bal_in: u64 = if (side == .asset1) self.balance1 else self.balance2;
        const bal_out: u64 = if (side == .asset1) self.balance2 else self.balance1;

        // output = (bal_out * effective_input) / (bal_in + effective_input)
        const numerator: u128 = @as(u128, bal_out) * @as(u128, effective_input);
        const denominator: u128 = @as(u128, bal_in) + @as(u128, effective_input);
        const output: u64 = @intCast(numerator / denominator);

        if (output == 0) return error.InsufficientLiquidity;
        if (output >= bal_out) return error.InsufficientLiquidity;

        // Update balances.
        switch (side) {
            .asset1 => {
                self.balance1 += input_amount;
                self.balance2 -= output;
            },
            .asset2 => {
                self.balance2 += input_amount;
                self.balance1 -= output;
            },
        }

        return SwapResult{
            .output_amount = output,
            .effective_input = effective_input,
            .fee_deducted = fee_deducted,
        };
    }

    // ------------------------------------------------------------------
    // LP token operations
    // ------------------------------------------------------------------

    pub const DepositResult = struct {
        lp_tokens_minted: u64,
    };

    /// Two-asset proportional deposit.
    /// LP tokens minted = supply * (amount1 / balance1)   (proportional).
    /// The caller must provide amounts in the correct ratio; this function
    /// uses amount1's proportion to compute LP tokens.
    pub fn deposit(self: *AMMPool, amount1: u64, amount2: u64) error{ ZeroDeposit, DisproportionateDeposit }!DepositResult {
        if (amount1 == 0 or amount2 == 0) return error.ZeroDeposit;

        // Check proportionality: amount1/balance1 should equal amount2/balance2.
        // Cross-multiply to compare: amount1 * balance2 vs amount2 * balance1.
        const lhs: u128 = @as(u128, amount1) * @as(u128, self.balance2);
        const rhs: u128 = @as(u128, amount2) * @as(u128, self.balance1);

        // Allow up to 0.1% deviation for rounding.
        const tolerance: u128 = rhs / 1000;
        const diff = if (lhs > rhs) lhs - rhs else rhs - lhs;
        if (diff > tolerance) return error.DisproportionateDeposit;

        // LP tokens minted proportional to share.
        const minted: u64 = @intCast((@as(u128, self.lp_token_supply) * @as(u128, amount1)) / @as(u128, self.balance1));
        if (minted == 0) return error.ZeroDeposit;

        self.balance1 += amount1;
        self.balance2 += amount2;
        self.lp_token_supply += minted;

        return DepositResult{ .lp_tokens_minted = minted };
    }

    pub const WithdrawResult = struct {
        amount1: u64,
        amount2: u64,
    };

    /// Withdraw by burning LP tokens.  Returns proportional amounts of both assets.
    pub fn withdraw(self: *AMMPool, lp_tokens: u64) error{ ZeroWithdrawal, InsufficientLPTokens }!WithdrawResult {
        if (lp_tokens == 0) return error.ZeroWithdrawal;
        if (lp_tokens > self.lp_token_supply) return error.InsufficientLPTokens;

        const amount1: u64 = @intCast((@as(u128, self.balance1) * @as(u128, lp_tokens)) / @as(u128, self.lp_token_supply));
        const amount2: u64 = @intCast((@as(u128, self.balance2) * @as(u128, lp_tokens)) / @as(u128, self.lp_token_supply));

        self.balance1 -= amount1;
        self.balance2 -= amount2;
        self.lp_token_supply -= lp_tokens;

        return WithdrawResult{ .amount1 = amount1, .amount2 = amount2 };
    }

    /// Single-asset deposit: deposit only one asset, accepting slippage.
    /// Equivalent to swapping half to the other asset then depositing both,
    /// but computed in one step.
    ///
    /// The LP tokens minted are based on the constant-product invariant:
    ///   new_lp = supply * (sqrt((balance + amount) / balance) - 1)
    ///
    /// Simplified using integer math:
    ///   new_lp = supply * (sqrt(balance + amount) - sqrt(balance)) / sqrt(balance)
    pub fn singleAssetDeposit(self: *AMMPool, side: SwapAsset, amount: u64) error{ ZeroDeposit, InsufficientLiquidity }!DepositResult {
        if (amount == 0) return error.ZeroDeposit;

        const bal: u64 = if (side == .asset1) self.balance1 else self.balance2;

        // Apply fee to half of the deposit (the half that is implicitly swapped).
        const fee_factor: u64 = BPS_DENOM - @as(u64, self.trading_fee);
        const half = amount / 2;
        const effective_half: u64 = @intCast((@as(u128, half) * fee_factor) / BPS_DENOM);
        // Total effective amount added to the pool for LP calculation.
        const effective_amount = (amount - half) + effective_half;

        // LP tokens = supply * effective_amount / (2 * bal + effective_amount)
        // This is the linearized approximation that is accurate for reasonable deposit sizes.
        const numerator: u128 = @as(u128, self.lp_token_supply) * @as(u128, effective_amount);
        const denominator: u128 = 2 * @as(u128, bal) + @as(u128, effective_amount);
        const minted: u64 = @intCast(numerator / denominator);

        if (minted == 0) return error.InsufficientLiquidity;

        switch (side) {
            .asset1 => self.balance1 += amount,
            .asset2 => self.balance2 += amount,
        }
        self.lp_token_supply += minted;

        return DepositResult{ .lp_tokens_minted = minted };
    }

    // ------------------------------------------------------------------
    // Fee voting
    // ------------------------------------------------------------------

    /// Record a fee vote from an LP holder.
    /// The vote is weighted by the voter's LP token holdings.
    pub fn recordFeeVote(self: *AMMPool, vote: FeeVote) !void {
        // Clamp the vote to the valid range.
        var clamped = vote;
        if (clamped.fee_bps > MAX_TRADING_FEE) clamped.fee_bps = MAX_TRADING_FEE;

        // Replace existing vote from same account, or append.
        for (self.fee_votes.items) |*existing| {
            if (std.mem.eql(u8, &existing.account, &clamped.account)) {
                existing.* = clamped;
                self.recomputeFee();
                return;
            }
        }
        try self.fee_votes.append(clamped);
        self.recomputeFee();
    }

    /// Compute the LP-token-weighted average trading fee from all votes.
    fn recomputeFee(self: *AMMPool) void {
        if (self.fee_votes.items.len == 0) return;

        var weighted_sum: u128 = 0;
        var total_weight: u128 = 0;
        for (self.fee_votes.items) |v| {
            weighted_sum += @as(u128, v.fee_bps) * @as(u128, v.lp_tokens);
            total_weight += @as(u128, v.lp_tokens);
        }
        if (total_weight == 0) return;

        self.trading_fee = @intCast(weighted_sum / total_weight);
    }

    // ------------------------------------------------------------------
    // AMM-DEX interaction: virtual offer
    // ------------------------------------------------------------------

    /// Get the AMM's effective exchange rate as a DEX Quality.
    /// quality = balance_out / balance_in  for a taker who pays `taker_pays_side`.
    pub fn getAMMOffer(self: *const AMMPool, taker_pays_side: SwapAsset) dex.Quality {
        // The AMM acts as a virtual offer.  A taker who pays asset1
        // receives asset2, so the quality (price) = balance1 / balance2.
        return switch (taker_pays_side) {
            .asset1 => dex.Quality{ .num = self.balance1, .den = self.balance2 },
            .asset2 => dex.Quality{ .num = self.balance2, .den = self.balance1 },
        };
    }

    /// The constant product k = balance1 * balance2.
    pub fn invariant(self: *const AMMPool) u128 {
        return @as(u128, self.balance1) * @as(u128, self.balance2);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

fn testAsset(code: []const u8, issuer_byte: u8) Asset {
    return Asset{
        .currency = CurrencyCode.fromStandard(code) catch unreachable,
        .issuer = [_]u8{issuer_byte} ** 20,
    };
}

test "create pool with initial deposit" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    var pool = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 2_000_000, 30);
    defer pool.deinit();

    try std.testing.expect(pool.balance1 == 1_000_000);
    try std.testing.expect(pool.balance2 == 2_000_000);
    try std.testing.expect(pool.lp_token_supply > 0);
    try std.testing.expect(pool.trading_fee == 30);
    try std.testing.expect(pool.auction_slot == null);

    // LP tokens = sqrt(1_000_000 * 2_000_000) = sqrt(2e12) ~ 1_414_213
    const expected_lp = std.math.sqrt(@as(u128, 1_000_000) * 2_000_000);
    try std.testing.expectEqual(@as(u64, @intCast(expected_lp)), pool.lp_token_supply);
}

test "swap changes balances correctly (constant product holds)" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    // Zero fee pool so we can check the pure constant product.
    var pool = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 1_000_000, 0);
    defer pool.deinit();

    const k_before = pool.invariant();

    const result = try pool.swap(.asset1, 100_000);
    try std.testing.expect(result.output_amount > 0);
    try std.testing.expect(result.fee_deducted == 0);

    // After a swap with zero fee, k should be >= k_before
    // (it can grow slightly due to integer rounding in favour of the pool).
    const k_after = pool.invariant();
    try std.testing.expect(k_after >= k_before);

    // Verify pool balances changed.
    try std.testing.expect(pool.balance1 == 1_000_000 + 100_000);
    try std.testing.expect(pool.balance2 == 1_000_000 - result.output_amount);
}

test "LP token minting proportional to deposit" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    var pool = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 2_000_000, 50);
    defer pool.deinit();

    const initial_supply = pool.lp_token_supply;

    // Deposit 10% more of each asset.
    const dep = try pool.deposit(100_000, 200_000);
    try std.testing.expect(dep.lp_tokens_minted > 0);

    // The minted tokens should be approximately 10% of the initial supply.
    // Allow 1% tolerance for rounding.
    const expected = initial_supply / 10;
    const diff = if (dep.lp_tokens_minted > expected) dep.lp_tokens_minted - expected else expected - dep.lp_tokens_minted;
    try std.testing.expect(diff <= expected / 100 + 1);
}

test "LP token burning returns proportional assets" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    var pool = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 2_000_000, 50);
    defer pool.deinit();

    const initial_lp = pool.lp_token_supply;

    // Burn half of LP tokens.
    const result = try pool.withdraw(initial_lp / 2);

    // Should get back ~50% of each asset.
    try std.testing.expect(result.amount1 >= 490_000 and result.amount1 <= 510_000);
    try std.testing.expect(result.amount2 >= 990_000 and result.amount2 <= 1_010_000);

    // Remaining supply should be the other half.
    try std.testing.expect(pool.lp_token_supply == initial_lp - initial_lp / 2);
}

test "trading fee applied correctly" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    // 100 bps = 1% fee
    var pool_fee = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 1_000_000, 100);
    defer pool_fee.deinit();

    // Zero fee pool for comparison.
    var pool_no_fee = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 1_000_000, 0);
    defer pool_no_fee.deinit();

    const result_fee = try pool_fee.swap(.asset1, 100_000);
    const result_no_fee = try pool_no_fee.swap(.asset1, 100_000);

    // With a fee, output should be strictly less.
    try std.testing.expect(result_fee.output_amount < result_no_fee.output_amount);
    try std.testing.expect(result_fee.fee_deducted > 0);
    try std.testing.expect(result_no_fee.fee_deducted == 0);

    // Fee should be 1% of input = 1000.
    try std.testing.expectEqual(@as(u64, 1000), result_fee.fee_deducted);
}

test "fee voting with weighted average" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    var pool = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 1_000_000, 50);
    defer pool.deinit();

    // Voter A: 300 bps, weight 750
    try pool.recordFeeVote(.{
        .account = [_]u8{0xAA} ** 20,
        .fee_bps = 300,
        .lp_tokens = 750,
    });

    // Voter B: 100 bps, weight 250
    try pool.recordFeeVote(.{
        .account = [_]u8{0xBB} ** 20,
        .fee_bps = 100,
        .lp_tokens = 250,
    });

    // Weighted average = (300*750 + 100*250) / (750+250) = (225000+25000)/1000 = 250
    try std.testing.expectEqual(@as(u16, 250), pool.trading_fee);
}

test "single-asset deposit" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    var pool = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 1_000_000, 0);
    defer pool.deinit();

    const initial_supply = pool.lp_token_supply;

    const dep = try pool.singleAssetDeposit(.asset1, 200_000);
    try std.testing.expect(dep.lp_tokens_minted > 0);

    // Single-asset deposit should mint fewer LP tokens than a proportional deposit
    // of the same total value (due to implicit swap slippage).
    // With zero fee and 200k into a 1M pool, minted should be roughly
    // supply * 200k / (2*1M + 200k) ~ supply * 200/2200 ~ 9.09% of supply.
    const upper_bound = initial_supply / 10; // ~10%
    try std.testing.expect(dep.lp_tokens_minted < upper_bound);
    try std.testing.expect(dep.lp_tokens_minted > 0);

    // balance1 should have increased.
    try std.testing.expect(pool.balance1 == 1_200_000);
}

test "AMM offer quality matches pool rate" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    var pool = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 2_000_000, 50);
    defer pool.deinit();

    const q = pool.getAMMOffer(.asset1);

    // quality = balance1/balance2 = 1_000_000/2_000_000 = 0.5
    // As a rational: num=1_000_000, den=2_000_000.
    try std.testing.expectEqual(@as(u64, 1_000_000), q.num);
    try std.testing.expectEqual(@as(u64, 2_000_000), q.den);

    // Reverse direction: quality = balance2/balance1 = 2.0
    const q2 = pool.getAMMOffer(.asset2);
    try std.testing.expectEqual(@as(u64, 2_000_000), q2.num);
    try std.testing.expectEqual(@as(u64, 1_000_000), q2.den);
}

test "large swap shows slippage" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    // Zero fee to isolate slippage from the constant-product curve.
    var pool = try AMMPool.init(std.testing.allocator, usd, eur, 1_000_000, 1_000_000, 0);
    defer pool.deinit();

    // Small swap: 1000 units -> should get close to 1000 out.
    const small = try pool.swap(.asset1, 1_000);
    // Effective rate: output / input.
    const small_rate = small.output_amount * 10_000 / 1_000; // scaled by 10000

    // Reset pool.
    pool.balance1 = 1_000_000;
    pool.balance2 = 1_000_000;

    // Large swap: 500,000 units -> significant slippage.
    const large = try pool.swap(.asset1, 500_000);
    const large_rate = large.output_amount * 10_000 / 500_000;

    // The large swap should have a worse effective rate (more slippage).
    try std.testing.expect(large_rate < small_rate);

    // The large swap should return less than 500,000 (can't get 1:1 at this size).
    try std.testing.expect(large.output_amount < 500_000);
}

test "pool rejects zero deposit" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    const result = AMMPool.init(std.testing.allocator, usd, eur, 0, 1_000_000, 50);
    try std.testing.expectError(error.ZeroDeposit, result);
}

test "pool rejects fee above maximum" {
    const usd = testAsset("USD", 0x01);
    const eur = testAsset("EUR", 0x02);

    const result = AMMPool.init(std.testing.allocator, usd, eur, 1_000, 1_000, 1001);
    try std.testing.expectError(error.FeeTooHigh, result);
}
