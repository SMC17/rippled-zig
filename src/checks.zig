const std = @import("std");
const types = @import("types.zig");

/// Checks - Deferred payments similar to paper checks
pub const CheckManager = struct {
    allocator: std.mem.Allocator,
    checks: std.ArrayList(Check),

    pub fn init(allocator: std.mem.Allocator) CheckManager {
        return CheckManager{
            .allocator = allocator,
            .checks = std.ArrayList(Check).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *CheckManager) void {
        self.checks.deinit();
    }

    /// Create a new check
    pub fn createCheck(self: *CheckManager, check: Check) !void {
        // Validate
        if (std.mem.eql(u8, &check.sender, &check.destination)) {
            return error.CannotCheckSelf;
        }

        try self.checks.append(check);
    }

    /// Cash a check
    pub fn cashCheck(self: *CheckManager, check_id: [32]u8, amount: ?types.Amount) !types.Amount {
        for (self.checks.items, 0..) |check, i| {
            if (std.mem.eql(u8, &check.check_id, &check_id)) {
                // Determine cash amount
                const cash_amount = if (amount) |amt| blk: {
                    // Validate amount doesn't exceed check
                    switch (amt) {
                        .xrp => |drops| {
                            if (check.send_max.isXRP()) {
                                const max_drops = switch (check.send_max) {
                                    .xrp => |d| d,
                                    else => unreachable,
                                };
                                if (drops > max_drops) return error.AmountExceedsCheck;
                            }
                        },
                        else => {},
                    }
                    break :blk amt;
                } else check.send_max;

                // Check expiration
                if (check.expiration) |exp| {
                    if (std.time.timestamp() > exp) {
                        _ = self.checks.swapRemove(i);
                        return error.CheckExpired;
                    }
                }

                _ = self.checks.swapRemove(i);
                return cash_amount;
            }
        }
        return error.CheckNotFound;
    }

    /// Cancel a check
    pub fn cancelCheck(self: *CheckManager, check_id: [32]u8, account: types.AccountID) !void {
        for (self.checks.items, 0..) |check, i| {
            if (std.mem.eql(u8, &check.check_id, &check_id)) {
                // Only sender or destination can cancel
                const is_sender = std.mem.eql(u8, &check.sender, &account);
                const is_dest = std.mem.eql(u8, &check.destination, &account);

                if (!is_sender and !is_dest) {
                    return error.CannotCancelCheck;
                }

                _ = self.checks.swapRemove(i);
                return;
            }
        }
        return error.CheckNotFound;
    }
};

/// A check object
pub const Check = struct {
    check_id: [32]u8,
    sender: types.AccountID,
    destination: types.AccountID,
    send_max: types.Amount,
    sequence: u32,
    expiration: ?i64 = null,
    destination_tag: ?u32 = null,
    invoice_id: ?[32]u8 = null,
};

/// CheckCreate transaction
pub const CheckCreateTransaction = struct {
    base: types.Transaction,
    destination: types.AccountID,
    send_max: types.Amount,
    destination_tag: ?u32 = null,
    expiration: ?i64 = null,
    invoice_id: ?[32]u8 = null,

    pub fn create(
        account: types.AccountID,
        destination: types.AccountID,
        send_max: types.Amount,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) CheckCreateTransaction {
        return CheckCreateTransaction{
            .base = types.Transaction{
                .tx_type = .check_create,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .destination = destination,
            .send_max = send_max,
        };
    }

    pub fn validate(self: *const CheckCreateTransaction) !void {
        // Cannot send check to self
        if (std.mem.eql(u8, &self.base.account, &self.destination)) {
            return error.CannotCheckSelf;
        }

        // Validate amount
        switch (self.send_max) {
            .xrp => |drops| if (drops == 0) return error.ZeroAmount,
            .iou => |iou| if (iou.value == 0) return error.ZeroAmount,
        }
    }
};

/// CheckCash transaction
pub const CheckCashTransaction = struct {
    base: types.Transaction,
    check_id: [32]u8,
    amount: ?types.Amount = null,
    deliver_min: ?types.Amount = null,

    pub fn create(
        account: types.AccountID,
        check_id: [32]u8,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) CheckCashTransaction {
        return CheckCashTransaction{
            .base = types.Transaction{
                .tx_type = .check_cash,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .check_id = check_id,
        };
    }

    pub fn validate(self: *const CheckCashTransaction) !void {
        // Must specify either amount or deliver_min
        if (self.amount == null and self.deliver_min == null) {
            return error.MissingAmountOrDeliverMin;
        }

        // Cannot specify both
        if (self.amount != null and self.deliver_min != null) {
            return error.CannotSpecifyBoth;
        }
    }
};

/// CheckCancel transaction
pub const CheckCancelTransaction = struct {
    base: types.Transaction,
    check_id: [32]u8,

    pub fn create(
        account: types.AccountID,
        check_id: [32]u8,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) CheckCancelTransaction {
        return CheckCancelTransaction{
            .base = types.Transaction{
                .tx_type = .check_cancel,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .check_id = check_id,
        };
    }
};

test "check manager" {
    const allocator = std.testing.allocator;
    var manager = CheckManager.init(allocator);
    defer manager.deinit();

    const check = Check{
        .check_id = [_]u8{1} ** 32,
        .sender = [_]u8{1} ** 20,
        .destination = [_]u8{2} ** 20,
        .send_max = types.Amount.fromXRP(1000 * types.XRP),
        .sequence = 1,
    };

    try manager.createCheck(check);
    try std.testing.expectEqual(@as(usize, 1), manager.checks.items.len);
}

test "check create transaction" {
    const account = [_]u8{1} ** 20;
    const destination = [_]u8{2} ** 20;
    const send_max = types.Amount.fromXRP(500 * types.XRP);

    const tx = CheckCreateTransaction.create(
        account,
        destination,
        send_max,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.check_create, tx.base.tx_type);
}

test "check validation prevents self-send" {
    const account = [_]u8{1} ** 20;
    const send_max = types.Amount.fromXRP(500 * types.XRP);

    const tx = CheckCreateTransaction.create(
        account,
        account, // Same as sender!
        send_max,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try std.testing.expectError(error.CannotCheckSelf, tx.validate());
}
