//! XRPL Lending Protocol (v3.0.0) - Amendment-gated
//! Spec not final; validator vote expected. This module provides a clear interface
//! scaffold for when the amendment is enabled.
//!
//! Design surface (stub until v3.0.0 spec):
//! - LendingPool: pool state (asset, supply, borrowed)
//! - Lend / Borrow ops: validation and state update hooks
//! - canLend / canBorrow: gate checks

const std = @import("std");
const types = @import("types.zig");

/// Lending amendment identifier (placeholder until spec final)
pub const LENDING_AMENDMENT_ID = "LENDING_AMENDMENT_PLACEHOLDER";

/// Whether the lending amendment is enabled (configurable)
pub var lending_enabled: bool = false;

/// Lending pool state (stub for v3 spec)
/// Expected fields: pool_id, asset, total_supply, total_borrowed, collateralization_ratio
pub const LendingPool = struct {
    pool_id: [32]u8,
    asset: types.Currency = .xrp,
    total_supply: types.Drops = 0,
    total_borrowed: types.Drops = 0,
};

/// Lend operation request (stub)
pub const LendRequest = struct {
    pool_id: [32]u8,
    amount: types.Drops,
    // Future: lp_token_mint, slippage, etc.
};

/// Borrow operation request (stub)
pub const BorrowRequest = struct {
    pool_id: [32]u8,
    amount: types.Drops,
    // Future: collateral_account, max_rate, etc.
};

/// Enable lending amendment (call when amendment passes)
pub fn enableLendingAmendment() void {
    lending_enabled = true;
}

/// Check if a lending operation is allowed
pub fn canLend() bool {
    return lending_enabled;
}

/// Check if a borrow operation is allowed
pub fn canBorrow() bool {
    return lending_enabled;
}

/// Validate lend request (stub; full logic depends on v3 spec)
pub fn validateLend(_: LendRequest) bool {
    return canLend();
}

/// Validate borrow request (stub; full logic depends on v3 spec)
pub fn validateBorrow(_: BorrowRequest) bool {
    return canBorrow();
}

test "lending amendment scaffold" {
    try std.testing.expect(!canLend());
    try std.testing.expect(!canBorrow());
    enableLendingAmendment();
    try std.testing.expect(canLend());
    try std.testing.expect(canBorrow());
}

test "lending validation hooks" {
    const req = LendRequest{
        .pool_id = [_]u8{0} ** 32,
        .amount = 1_000_000,
    };
    try std.testing.expect(!validateLend(req));
    enableLendingAmendment();
    try std.testing.expect(validateLend(req));
}
