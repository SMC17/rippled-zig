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

    const odd_hex = security.Security.InputValidator.validateHex("abc");
    if (odd_hex) |_| {
        return error.InvalidHexAccepted;
    } else |err| {
        if (err != error.InvalidHexLength) return err;
    }

    const bad_hex = security.Security.InputValidator.validateHex("0011GG");
    if (bad_hex) |_| {
        return error.NonHexAccepted;
    } else |err| {
        if (err != error.InvalidHexCharacter) return err;
    }

    const out_of_range = security.Security.InputValidator.validateNumber("9999999", 0, 1000);
    if (out_of_range) |_| {
        return error.OutOfRangeNumberAccepted;
    } else |err| {
        if (err != error.NumberOutOfRange) return err;
    }

    const null_byte = security.Security.InputValidator.validateString("abc\x00def", 32);
    if (null_byte) |_| {
        return error.NullByteAccepted;
    } else |err| {
        if (err != error.NullByteInInput) return err;
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

    // Budgeted mutational fuzz loop over input validators.
    var prng = std.Random.DefaultPrng.init(0xC0DEC0DE);
    const random = prng.random();
    const fuzz_cases_target: u32 = 25000;
    var fuzz_cases_executed: u32 = 0;
    var buf: [64]u8 = undefined;

    while (fuzz_cases_executed < fuzz_cases_target) : (fuzz_cases_executed += 1) {
        const len = random.uintAtMost(usize, buf.len);
        random.bytes(buf[0..len]);

        _ = security.Security.InputValidator.validateString(buf[0..len], 64) catch {};
        _ = security.Security.InputValidator.validateHex(buf[0..len]) catch {};
        _ = security.Security.InputValidator.validateNumber("123", 0, 1000) catch {};
    }

    std.debug.print("FUZZ_CASES: {d}\n", .{fuzz_cases_executed});
}
