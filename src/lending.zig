//! XRPL Lending Protocol (v3.0.0) - Amendment-gated
//! Spec not final; validator vote expected Jan 2026.
//! This module provides scaffolding for when the amendment is enabled.

const std = @import("std");
const types = @import("types.zig");

/// Lending amendment identifier (placeholder until spec final)
pub const LENDING_AMENDMENT_ID = "LENDING_AMENDMENT_PLACEHOLDER";

/// Whether the lending amendment is enabled (configurable)
pub var lending_enabled: bool = false;

/// Lending pool state (stub)
pub const LendingPool = struct {
    pool_id: [32]u8,
    asset: types.Currency = .xrp,
    total_supply: types.Drops = 0,
    total_borrowed: types.Drops = 0,
};

/// Enable lending amendment (call when amendment passes)
pub fn enableLendingAmendment() void {
    lending_enabled = true;
}

/// Check if a lending operation is allowed
pub fn canLend() bool {
    return lending_enabled;
}

test "lending amendment scaffold" {
    try std.testing.expect(!canLend());
    enableLendingAmendment();
    try std.testing.expect(canLend());
}
