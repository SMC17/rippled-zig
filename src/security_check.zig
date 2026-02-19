const std = @import("std");
const build_options = @import("build_options");
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

    // Seeded adversarial corpus + budgeted mutational fuzz loop over input validators.
    var prng = std.Random.DefaultPrng.init(0xC0DEC0DE);
    const random = prng.random();
    const fuzz_cases_target: u32 = build_options.gate_e_fuzz_cases;
    const corpus = [_][]const u8{
        "", // empty
        "0", // small numeric
        "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", // long hex
        "abc\x00def", // null byte injection
        "999999999999999999999999", // out-of-range numeric
        "DROP TABLE accounts;", // SQL-like payload
        "../../../../etc/passwd", // path traversal-like payload
        "{\"json\":\"payload\"}", // structured input
    };
    const nightly_extra_corpus = [_][]const u8{
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", // max-ish alpha payload
        "0000000000000000000000000000000000000000000000000000000000000000", // dense numeric/hex
        "\n\r\t\n\r\t", // control chars allowed set
        "%00%2e%2e%2f", // encoded traversal/null bytes
        "\\x00\\x01\\x7f\\xff", // escaped binary-like patterns
        "{\"nested\":{\"array\":[1,2,3],\"obj\":{\"k\":\"v\"}}}", // deep structured
    };
    const is_nightly = std.mem.eql(u8, build_options.gate_e_profile, "nightly");
    var fuzz_cases_executed: u32 = 0;
    var buf: [64]u8 = undefined;

    for (corpus) |seed| {
        _ = security.Security.InputValidator.validateString(seed, 64) catch {};
        _ = security.Security.InputValidator.validateHex(seed) catch {};
        _ = security.Security.InputValidator.validateNumber(seed, 0, 1000) catch {};
    }
    if (is_nightly) {
        for (nightly_extra_corpus) |seed| {
            _ = security.Security.InputValidator.validateString(seed, 128) catch {};
            _ = security.Security.InputValidator.validateHex(seed) catch {};
            _ = security.Security.InputValidator.validateNumber(seed, -1000, 1000) catch {};
        }
    }

    while (fuzz_cases_executed < fuzz_cases_target) : (fuzz_cases_executed += 1) {
        const len = random.uintAtMost(usize, buf.len);
        random.bytes(buf[0..len]);

        _ = security.Security.InputValidator.validateString(buf[0..len], 64) catch {};
        _ = security.Security.InputValidator.validateHex(buf[0..len]) catch {};
        _ = security.Security.InputValidator.validateNumber("123", 0, 1000) catch {};
    }

    // Property-based tx sequence fuzz: random tx sequences through validate + invariants
    const tx_fuzz_target: u32 = if (is_nightly) 5000 else 1500;
    var tx_fuzz_prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const tx_random = tx_fuzz_prng.random();
    var tx_fuzz_executed: u32 = 0;

    const tx_types = [_]types.TransactionType{ .payment, .account_set, .trust_set, .offer_create, .offer_cancel };
    var acc_buf: [5][20]u8 = undefined;
    for (&acc_buf, 0..) |*acc, i| {
        tx_random.bytes(acc);
        acc[0] = @intCast(i + 1); // Distinct first byte
    }

    while (tx_fuzz_executed < tx_fuzz_target) : (tx_fuzz_executed += 1) {
        var tx_state = ledger.AccountState.init(allocator);
        defer tx_state.deinit();
        var proc = try transaction.TransactionProcessor.init(allocator);
        defer proc.deinit();

        const num_accounts = tx_random.uintAtMost(u32, 4) + 1;
        for (acc_buf[0..num_accounts], 0..) |acc, i| {
            const bal = types.MIN_TX_FEE * (tx_random.uintAtMost(u64, 100) + 1);
            try tx_state.putAccount(.{
                .account = acc,
                .balance = bal,
                .flags = .{},
                .owner_count = 0,
                .previous_txn_id = [_]u8{0} ** 32,
                .previous_txn_lgr_seq = 1,
                .sequence = @intCast(i + 1),
            });
        }

        const num_txs = tx_random.uintAtMost(u32, 20) + 1;
        const sum_before = tx_state.sumBalances();
        for (0..num_txs) |_| {
            const acc_idx = tx_random.uintAtMost(usize, num_accounts - 1);
            const acc = tx_state.getAccount(acc_buf[acc_idx]) orelse continue;
            const fuzz_tx = types.Transaction{
                .tx_type = tx_types[tx_random.uintAtMost(usize, tx_types.len - 1)],
                .account = acc_buf[acc_idx],
                .fee = types.MIN_TX_FEE,
                .sequence = acc.sequence,
            };
            _ = proc.validateTransaction(&fuzz_tx, &tx_state) catch {};
        }
        const sum_after = tx_state.sumBalances();
        if (sum_before != sum_after) return error.InvariantViolation; // validate must not mutate
    }

    const total_corpus_seeds = corpus.len + if (is_nightly) nightly_extra_corpus.len else 0;
    std.debug.print("FUZZ_PROFILE: {s}\n", .{build_options.gate_e_profile});
    std.debug.print("CORPUS_SEEDS: {d}\n", .{total_corpus_seeds});
    std.debug.print("TX_FUZZ_CASES: {d}\n", .{tx_fuzz_executed});
    std.debug.print("CRASH_FREE: 1\n", .{});
    std.debug.print("FUZZ_CASES: {d}\n", .{fuzz_cases_executed});
}
