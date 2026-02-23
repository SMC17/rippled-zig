const std = @import("std");
const consensus = @import("consensus");
const ledger = consensus.ledger_mod;
const types = consensus.types_mod;

fn parseEnvU32(allocator: std.mem.Allocator, name: []const u8, default_value: u32) u32 {
    const v = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(v);
    return std.fmt.parseInt(u32, v, 10) catch default_value;
}

fn parseEnvI64(allocator: std.mem.Allocator, name: []const u8, default_value: i64) i64 {
    const v = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(v);
    return std.fmt.parseInt(i64, v, 10) catch default_value;
}

fn parseEnvF64(allocator: std.mem.Allocator, name: []const u8, default_value: f64) f64 {
    const v = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(v);
    return std.fmt.parseFloat(f64, v) catch default_value;
}

fn parseEnvString(allocator: std.mem.Allocator, name: []const u8, default_value: []const u8) ![]u8 {
    const v = std.process.getEnvVarOwned(allocator, name) catch return allocator.dupe(u8, default_value);
    return v;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // argv0
    const out_path = args.next() orelse {
        std.debug.print("usage: zig run tools/consensus_experiment.zig -- <output.json>\n", .{});
        return error.InvalidArguments;
    };

    const label = try parseEnvString(allocator, "CONS_EXP_LABEL", "baseline");
    defer allocator.free(label);

    const validators = parseEnvU32(allocator, "CONS_EXP_VALIDATORS", 4);
    const max_iterations = parseEnvU32(allocator, "CONS_EXP_MAX_ITERATIONS", 200);

    const cfg = consensus.ConsensusConfig{
        .final_threshold = parseEnvF64(allocator, "CONS_EXP_FINAL_THRESHOLD", 0.80),
        .open_phase_ticks = parseEnvU32(allocator, "CONS_EXP_OPEN_PHASE_TICKS", 20),
        .open_phase_ms = parseEnvI64(allocator, "CONS_EXP_OPEN_PHASE_MS", 2_000),
        .establish_phase_ticks = parseEnvU32(allocator, "CONS_EXP_ESTABLISH_PHASE_TICKS", 5),
        .consensus_round_ticks = parseEnvU32(allocator, "CONS_EXP_CONSENSUS_ROUND_TICKS", 5),
    };

    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var engine = try consensus.ConsensusEngine.initWithConfig(allocator, &lm, cfg);
    defer engine.deinit();

    var i: u32 = 0;
    while (i < validators) : (i += 1) {
        const fill: u8 = @intCast((i % 240) + 1);
        const validator = consensus.ValidatorInfo{
            .public_key = [_]u8{fill} ** 33,
            .node_id = [_]u8{fill + 10} ** 32,
            .is_trusted = true,
        };
        try engine.addValidator(validator);
    }

    const empty_txs: []const types.Transaction = &[_]types.Transaction{};
    try engine.startRound(empty_txs);

    const current_ledger_hash = engine.ledger_manager.getCurrentLedger().hash;
    for (engine.unl.items) |validator| {
        const proposal = consensus.Proposal{
            .validator_id = validator.node_id,
            .ledger_seq = engine.ledger_manager.getCurrentLedger().sequence + 1,
            .close_time = 0,
            .position = consensus.Position{
                .prior_ledger = current_ledger_hash,
                .transactions = &[_]types.TxHash{},
                .close_time = 0,
            },
            .signature = [_]u8{0} ** 64,
            .timestamp = 0,
        };
        try engine.processProposal(proposal);
    }

    var accepted = false;
    var iterations: u32 = 0;
    while (!accepted and iterations < max_iterations) : (iterations += 1) {
        accepted = try engine.runRoundStep();
    }

    const status = engine.getStatus();

    const out_file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out_file.close();
    var out_buf: [4096]u8 = undefined;
    var file_writer: std.fs.File.Writer = .init(out_file, &out_buf);
    const w = &file_writer.interface;

    try w.print(
        \\{{
        \\  "schema_version": 1,
        \\  "label": "{s}",
        \\  "deterministic": true,
        \\  "config": {{
        \\    "final_threshold": {d},
        \\    "open_phase_ticks": {d},
        \\    "open_phase_ms": {d},
        \\    "establish_phase_ticks": {d},
        \\    "consensus_round_ticks": {d}
        \\  }},
        \\  "inputs": {{
        \\    "validators": {d},
        \\    "max_iterations": {d}
        \\  }},
        \\  "result": {{
        \\    "accepted": {s},
        \\    "iterations_executed": {d},
        \\    "round_number": {d},
        \\    "validators": {d},
        \\    "proposals_received": {d},
        \\    "state": "{s}"
        \\  }}
        \\}}
    , .{
        label,
        cfg.final_threshold,
        cfg.open_phase_ticks,
        cfg.open_phase_ms,
        cfg.establish_phase_ticks,
        cfg.consensus_round_ticks,
        validators,
        max_iterations,
        if (accepted) "true" else "false",
        iterations,
        status.round_number,
        status.validators,
        status.proposals_received,
        @tagName(status.state),
    });
    try w.flush();
}
