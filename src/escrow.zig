const std = @import("std");
const types = @import("types.zig");

/// Escrow transactions - time-locked or condition-locked XRP
pub const EscrowManager = struct {
    allocator: std.mem.Allocator,
    escrows: std.ArrayList(Escrow),

    pub fn init(allocator: std.mem.Allocator) EscrowManager {
        return EscrowManager{
            .allocator = allocator,
            .escrows = std.ArrayList(Escrow).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *EscrowManager) void {
        for (self.escrows.items) |*escrow| {
            if (escrow.condition) |cond| {
                self.allocator.free(cond);
            }
        }
        self.escrows.deinit();
    }

    /// Create an escrow
    pub fn createEscrow(self: *EscrowManager, escrow: Escrow) !void {
        try self.escrows.append(escrow);
    }

    /// Finish an escrow (release funds)
    pub fn finishEscrow(self: *EscrowManager, owner: types.AccountID, sequence: u32, fulfillment: ?[]const u8) !types.Drops {
        for (self.escrows.items, 0..) |escrow, i| {
            if (std.mem.eql(u8, &escrow.account, &owner) and escrow.sequence == sequence) {
                // Check time constraint
                const now = std.time.timestamp();
                if (escrow.finish_after) |finish_after| {
                    if (now < finish_after) return error.EscrowNotYetAvailable;
                }
                if (escrow.cancel_after) |cancel_after| {
                    if (now >= cancel_after) return error.EscrowExpired;
                }

                // Check condition if present
                if (escrow.condition) |_| {
                    if (fulfillment == null) return error.FulfillmentRequired;
                    // TODO: Verify condition against fulfillment (crypto condition)
                }

                const amount = escrow.amount;
                _ = self.escrows.swapRemove(i);
                return amount;
            }
        }
        return error.EscrowNotFound;
    }

    /// Cancel an escrow
    pub fn cancelEscrow(self: *EscrowManager, owner: types.AccountID, sequence: u32) !types.Drops {
        for (self.escrows.items, 0..) |escrow, i| {
            if (std.mem.eql(u8, &escrow.account, &owner) and escrow.sequence == sequence) {
                // Check if cancellation is allowed
                const now = std.time.timestamp();
                if (escrow.cancel_after) |cancel_after| {
                    if (now < cancel_after) return error.CannotCancelYet;
                }

                const amount = escrow.amount;
                _ = self.escrows.swapRemove(i);
                return amount;
            }
        }
        return error.EscrowNotFound;
    }
};

/// An escrow holding XRP
pub const Escrow = struct {
    account: types.AccountID,
    destination: types.AccountID,
    amount: types.Drops,
    sequence: u32,
    finish_after: ?i64 = null,
    cancel_after: ?i64 = null,
    condition: ?[]const u8 = null,
    destination_tag: ?u32 = null,
};

/// EscrowCreate transaction
pub const EscrowCreateTransaction = struct {
    base: types.Transaction,
    destination: types.AccountID,
    amount: types.Drops,
    finish_after: ?i64 = null,
    cancel_after: ?i64 = null,
    condition: ?[]const u8 = null,
    destination_tag: ?u32 = null,

    pub fn create(
        account: types.AccountID,
        destination: types.AccountID,
        amount: types.Drops,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) EscrowCreateTransaction {
        return EscrowCreateTransaction{
            .base = types.Transaction{
                .tx_type = .escrow_create,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .destination = destination,
            .amount = amount,
        };
    }

    /// Validate escrow creation
    pub fn validate(self: *const EscrowCreateTransaction) !void {
        if (self.amount == 0) return error.ZeroAmount;

        // Must have either time lock or condition
        if (self.finish_after == null and self.condition == null) {
            return error.MalformedEscrow;
        }

        // If both times specified, finish must be before cancel
        if (self.finish_after != null and self.cancel_after != null) {
            if (self.finish_after.? >= self.cancel_after.?) {
                return error.InvalidTimes;
            }
        }
    }
};

test "escrow manager" {
    const allocator = std.testing.allocator;
    var manager = EscrowManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.escrows.items.len);
}

test "escrow create transaction" {
    const account = [_]u8{1} ** 20;
    const destination = [_]u8{2} ** 20;
    const amount = 100 * types.XRP;

    var tx = EscrowCreateTransaction.create(
        account,
        destination,
        amount,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    // Must have time or condition
    try std.testing.expectError(error.MalformedEscrow, tx.validate());

    // Add time lock
    tx.finish_after = std.time.timestamp() + 3600; // 1 hour
    try tx.validate();
}
