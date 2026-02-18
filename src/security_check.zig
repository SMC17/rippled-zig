const std = @import("std");
const security = @import("security.zig");
const ledger = @import("ledger.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const huge = "x" ** 4096;
    const long_result = security.Security.InputValidator.validateString(huge, 1024);
    if (long_result) |_| {
        return error.OversizedInputAccepted;
    } else |err| {
        if (err != error.InputTooLong) return err;
    }

    var limiter = security.Security.RateLimiter.init(allocator, 1000, 5);
    defer limiter.deinit();

    const ip = [_]u8{ 10, 0, 0, 1 } ++ [_]u8{0} ** 12;

    var allowed: u32 = 0;
    for (0..10) |_| {
        if (try limiter.checkLimit(ip)) {
            allowed += 1;
        }
    }
    if (allowed != 5) return error.RateLimitBypass;

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const account = [_]u8{1} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    const tx = types.Transaction{
        .tx_type = .payment,
        .account = account,
        .fee = 0,
        .sequence = 1,
    };

    const result = try processor.validateTransaction(&tx, &state);
    if (result != .tem_malformed) return error.InvalidFeeAccepted;
}
