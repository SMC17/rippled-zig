const std = @import("std");
const invariants = @import("invariants.zig");
const ledger = @import("ledger.zig");
const types = @import("types.zig");

fn envU32(allocator: std.mem.Allocator, name: []const u8, default_value: u32) u32 {
    const v = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(v);
    return std.fmt.parseInt(u32, v, 10) catch default_value;
}

fn envU64(allocator: std.mem.Allocator, name: []const u8, default_value: u64) u64 {
    const v = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(v);
    return std.fmt.parseInt(u64, v, 10) catch default_value;
}

fn envString(allocator: std.mem.Allocator, name: []const u8, default_value: []const u8) ![]u8 {
    const v = std.process.getEnvVarOwned(allocator, name) catch return allocator.dupe(u8, default_value);
    return v;
}

fn writeFailureJson(path: []const u8, scenario: []const u8, failure: invariants.InvariantFailure, ctx: anytype) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var fw: std.fs.File.Writer = .init(file, &buf);
    const w = &fw.interface;

    try w.print(
        \\{{
        \\  "schema_version": 1,
        \\  "status": "fail",
        \\  "deterministic": true,
        \\  "scenario": "{s}",
        \\  "failure": {{
    , .{scenario});

    switch (failure) {
        .balance_conservation => |f| {
            try w.print(
                \\    "invariant": "balance_conservation",
                \\    "reason": "sum_plus_fees_not_equal_expected",
                \\    "context": {{
                \\      "sum": {d},
                \\      "fees_destroyed": {d},
                \\      "expected_total": {d}
                \\    }}
            , .{ f.sum, f.fees_destroyed, f.expected });
        },
        .sequence_monotonicity => |f| {
            try w.print(
                \\    "invariant": "sequence_monotonicity",
                \\    "reason": "account_sequence_decreased",
                \\    "context": {{
                \\      "account_prefix": "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
                \\      "before_seq": {d},
                \\      "after_seq": {d}
                \\    }}
            , .{
                f.account_prefix[0], f.account_prefix[1], f.account_prefix[2], f.account_prefix[3],
                f.account_prefix[4], f.account_prefix[5], f.account_prefix[6], f.account_prefix[7],
                f.before_seq, f.after_seq,
            });
        },
        .ledger_sequence_monotonicity => |f| {
            try w.print(
                \\    "invariant": "ledger_sequence_monotonicity",
                \\    "reason": "ledger_sequence_not_increasing",
                \\    "context": {{
                \\      "prev_seq": {d},
                \\      "new_seq": {d}
                \\    }}
            , .{ f.prev_seq, f.new_seq });
        },
        .total_coins_within_bound => |f| {
            try w.print(
                \\    "invariant": "total_coins_within_bound",
                \\    "reason": "total_coins_exceeds_max_xrp",
                \\    "context": {{
                \\      "total_coins": {d},
                \\      "max_xrp": {d}
                \\    }}
            , .{ f.total_coins, f.max_xrp });
        },
    }

    try w.print(
        \\  }},
        \\  "run_context": {{
        \\    "nodes": {d},
        \\    "rounds": {d},
        \\    "base_ledger_seq": {d},
        \\    "latest_ledger_seq": {d}
        \\  }}
        \\}}
    , .{ ctx.nodes, ctx.rounds, ctx.base_ledger_seq, ctx.latest_ledger_seq });
    try w.flush();
}

fn writePassJson(path: []const u8, scenario: []const u8, ctx: anytype) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var fw: std.fs.File.Writer = .init(file, &buf);
    const w = &fw.interface;

    try w.print(
        \\{{
        \\  "schema_version": 1,
        \\  "status": "pass",
        \\  "deterministic": true,
        \\  "scenario": "{s}",
        \\  "checked_invariants": [
        \\    "balance_conservation",
        \\    "sequence_monotonicity",
        \\    "ledger_sequence_monotonicity"
        \\  ],
        \\  "run_context": {{
        \\    "nodes": {d},
        \\    "rounds": {d},
        \\    "base_ledger_seq": {d},
        \\    "latest_ledger_seq": {d}
        \\  }}
        \\}}
    , .{ scenario, ctx.nodes, ctx.rounds, ctx.base_ledger_seq, ctx.latest_ledger_seq });
    try w.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse return error.InvalidArguments;

    const scenario = try envString(allocator, "INV_SCENARIO", "standard");
    defer allocator.free(scenario);
    const fail_mode = try envString(allocator, "INV_FAIL_MODE", "none");
    defer allocator.free(fail_mode);

    const nodes = envU32(allocator, "INV_NODES", 5);
    const rounds = envU32(allocator, "INV_ROUNDS", 20);
    const base_ledger_seq = envU64(allocator, "INV_BASE_LEDGER_SEQ", 1_000_000);
    const latest_ledger_seq = envU64(allocator, "INV_LATEST_LEDGER_SEQ", base_ledger_seq + rounds);

    const ctx = struct {
        nodes: u32,
        rounds: u32,
        base_ledger_seq: u64,
        latest_ledger_seq: u64,
    }{
        .nodes = nodes,
        .rounds = rounds,
        .base_ledger_seq = base_ledger_seq,
        .latest_ledger_seq = latest_ledger_seq,
    };

    var before = ledger.AccountState.init(allocator);
    defer before.deinit();
    var after = ledger.AccountState.init(allocator);
    defer after.deinit();

    const acc_a = [_]u8{1} ** 20;
    const acc_b = [_]u8{2} ** 20;

    const seed_balance: u64 = (@as(u64, nodes) * 1_000_000) + (@as(u64, rounds) * 1_000);
    const transfer: u64 = @max(@as(u64, 1), @as(u64, rounds) * 10);
    const fees_destroyed: u64 = @as(u64, rounds);
    const before_a_balance: u64 = seed_balance + 500_000;
    const before_b_balance: u64 = seed_balance;
    const after_a_balance: u64 = before_a_balance - transfer - fees_destroyed;
    var after_b_balance: u64 = before_b_balance + transfer;

    const seq_a_before: u32 = 10 + rounds;
    const seq_b_before: u32 = 20 + rounds;
    var seq_a_after: u32 = seq_a_before + 1;
    const seq_b_after: u32 = seq_b_before;
    var observed_latest_seq: u64 = latest_ledger_seq;

    if (std.mem.eql(u8, fail_mode, "balance")) {
        after_b_balance += 1; // break sum conservation deterministically
    } else if (std.mem.eql(u8, fail_mode, "sequence")) {
        seq_a_after = seq_a_before - 1;
    } else if (std.mem.eql(u8, fail_mode, "ledger_sequence")) {
        observed_latest_seq = base_ledger_seq;
    }

    try before.putAccount(.{
        .account = acc_a,
        .balance = before_a_balance,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = seq_a_before,
    });
    try before.putAccount(.{
        .account = acc_b,
        .balance = before_b_balance,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = seq_b_before,
    });

    try after.putAccount(.{
        .account = acc_a,
        .balance = after_a_balance,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = seq_a_after,
    });
    try after.putAccount(.{
        .account = acc_b,
        .balance = after_b_balance,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = seq_b_after,
    });

    if (invariants.checkBalanceConservation(&after, fees_destroyed, before.sumBalances())) |failure| {
        try writeFailureJson(out_path, scenario, failure, ctx);
        return error.InvariantViolation;
    }
    if (invariants.checkSequenceMonotonicity(&before, &after)) |failure| {
        try writeFailureJson(out_path, scenario, failure, ctx);
        return error.InvariantViolation;
    }
    const prev_seq: types.LedgerSequence = @intCast(base_ledger_seq);
    const new_seq: types.LedgerSequence = @intCast(observed_latest_seq);
    if (invariants.checkLedgerSequenceMonotonicity(prev_seq, new_seq)) |failure| {
        try writeFailureJson(out_path, scenario, failure, ctx);
        return error.InvariantViolation;
    }

    try writePassJson(out_path, scenario, ctx);
}
