const std = @import("std");
const types = @import("types.zig");

/// XRPL Clawback (XLS-39) Implementation
///
/// Allows token issuers to claw back (reclaim) issued tokens from holders.
/// Requirements:
///   - Issuer must have lsfAllowTrustLineClawback set BEFORE any trust lines
///   - Can only claw back tokens the issuer has issued (not XRP)
///   - Amount must be positive
///   - Cannot claw back more than the holder's balance

pub const CLAWBACK_TX_TYPE: u16 = 30;

/// Account flag for allowing clawback (must be set before any trust lines exist)
pub const lsfAllowTrustLineClawback: u32 = 0x80000000;

pub const ClawbackTx = struct {
    account: types.AccountID, // the issuer performing the clawback
    amount: ClawbackAmount, // how much to claw back and from whom
    fee: types.Drops,
    sequence: u32,

    pub const ClawbackAmount = struct {
        value: u64, // amount in token units (mantissa)
        currency: types.CurrencyCode,
        holder: types.AccountID, // who the tokens are being clawed back from
    };

    /// Validate the clawback transaction
    pub fn validate(self: ClawbackTx) !void {
        // Amount must be positive
        if (self.amount.value == 0) return error.InvalidAmount;
        // Cannot claw back XRP
        const zero_currency = types.CurrencyCode{ .bytes = [_]u8{0} ** 20 };
        if (std.mem.eql(u8, &self.amount.currency.bytes, &zero_currency.bytes)) {
            return error.CannotClawbackXRP;
        }
        // Issuer cannot claw back from themselves
        if (std.mem.eql(u8, &self.account, &self.amount.holder)) {
            return error.CannotClawbackSelf;
        }
        // Fee must be valid
        if (self.fee < types.MIN_TX_FEE) return error.FeeTooLow;
    }
};

/// Check if an account has the clawback flag enabled
pub fn hasClawbackEnabled(account_flags: u32) bool {
    return (account_flags & lsfAllowTrustLineClawback) != 0;
}

/// Execute a clawback against a trust line balance
pub fn executeClawback(
    holder_balance: u64,
    clawback_amount: u64,
) !struct { new_balance: u64, actual_clawback: u64 } {
    if (clawback_amount == 0) return error.InvalidAmount;
    // Can only claw back up to the holder's balance
    const actual = @min(clawback_amount, holder_balance);
    return .{
        .new_balance = holder_balance - actual,
        .actual_clawback = actual,
    };
}

// ── Tests ──

test "clawback validation" {
    const issuer = [_]u8{0x01} ** 20;
    const holder = [_]u8{0x02} ** 20;
    const usd = types.CurrencyCode.fromStandard("USD") catch unreachable;

    const valid = ClawbackTx{
        .account = issuer,
        .amount = .{ .value = 100, .currency = usd, .holder = holder },
        .fee = 12,
        .sequence = 1,
    };
    try valid.validate();
}

test "clawback rejects XRP" {
    const issuer = [_]u8{0x01} ** 20;
    const holder = [_]u8{0x02} ** 20;
    const xrp = types.CurrencyCode{ .bytes = [_]u8{0} ** 20 };

    const tx = ClawbackTx{
        .account = issuer,
        .amount = .{ .value = 100, .currency = xrp, .holder = holder },
        .fee = 12,
        .sequence = 1,
    };
    try std.testing.expectError(error.CannotClawbackXRP, tx.validate());
}

test "clawback rejects self" {
    const issuer = [_]u8{0x01} ** 20;
    const usd = types.CurrencyCode.fromStandard("USD") catch unreachable;

    const tx = ClawbackTx{
        .account = issuer,
        .amount = .{ .value = 100, .currency = usd, .holder = issuer },
        .fee = 12,
        .sequence = 1,
    };
    try std.testing.expectError(error.CannotClawbackSelf, tx.validate());
}

test "execute clawback partial" {
    // Holder has 50, clawback 100 → only get 50
    const result = try executeClawback(50, 100);
    try std.testing.expectEqual(@as(u64, 0), result.new_balance);
    try std.testing.expectEqual(@as(u64, 50), result.actual_clawback);
}

test "execute clawback full" {
    const result = try executeClawback(200, 100);
    try std.testing.expectEqual(@as(u64, 100), result.new_balance);
    try std.testing.expectEqual(@as(u64, 100), result.actual_clawback);
}

test "clawback flag check" {
    try std.testing.expect(!hasClawbackEnabled(0));
    try std.testing.expect(hasClawbackEnabled(lsfAllowTrustLineClawback));
    try std.testing.expect(hasClawbackEnabled(0x80000001)); // other flags set too
}
