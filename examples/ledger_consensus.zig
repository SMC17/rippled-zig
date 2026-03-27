// ============================================================================
// EXPERIMENTAL -- This demo exercises the consensus engine simulation, which
// is outside the v1 toolkit release promise. Kept for research and integration
// testing. For toolkit examples see:
//   examples/encode_transaction.zig
//   examples/sign_and_verify.zig
//   examples/address_encoding.zig
//   examples/rpc_conformance.zig
// ============================================================================
const std = @import("std");
const ledger = @import("ledger.zig");
const consensus = @import("consensus.zig");
const types = @import("types.zig");

/// EXPERIMENTAL: Simulating the consensus module in isolation
/// (Depends on node-simulation modules outside the v1 toolkit surface.)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("XRP Ledger Consensus Example\n", .{});
    std.debug.print("=============================\n\n", .{});

    // 1. Initialize ledger manager
    std.debug.print("1. Initializing ledger manager...\n", .{});
    var ledger_manager = try ledger.LedgerManager.init(allocator);
    defer ledger_manager.deinit();

    const genesis = ledger_manager.getCurrentLedger();
    std.debug.print("   Genesis ledger: seq={}, coins={} XRP\n", .{
        genesis.sequence,
        genesis.total_coins / types.XRP,
    });

    // 2. Initialize consensus engine
    std.debug.print("\n2. Initializing consensus engine...\n", .{});
    var consensus_engine = try consensus.ConsensusEngine.init(allocator);
    defer consensus_engine.deinit();

    std.debug.print("   Consensus state: {s}\n", .{@tagName(consensus_engine.state)});

    // 3. Add some simulated validators to the local UNL set
    std.debug.print("\n3. Adding simulated validators to UNL...\n", .{});
    const validator_count = 5;
    var i: u8 = 0;
    while (i < validator_count) : (i += 1) {
        var validator = consensus.ValidatorInfo{
            .public_key = [_]u8{i} ** 33,
            .node_id = [_]u8{i + 100} ** 32,
            .is_trusted = true,
        };
        try consensus_engine.addValidator(validator);
    }
    std.debug.print("   Added {} simulated validators to UNL\n", .{validator_count});

    // 4. Simulate consensus rounds
    std.debug.print("\n4. Running consensus rounds...\n", .{});
    const num_rounds = 5;
    var round: u32 = 0;
    while (round < num_rounds) : (round += 1) {
        std.debug.print("\n   === Round {} ===\n", .{round + 1});

        // Start consensus round
        try consensus_engine.startRound();
        std.debug.print("   - Opened consensus round\n", .{});

        // Simulate transaction collection and validation
        std.debug.print("   - Collecting candidate transactions...\n", .{});
        std.debug.print("   - Exchanging proposals with simulated validators...\n", .{});
        std.debug.print("   - Reaching 80% consensus threshold...\n", .{});

        // Close the ledger with empty transaction set
        const empty_txs: []const types.Transaction = &[_]types.Transaction{};
        const new_ledger = try ledger_manager.closeLedger(empty_txs);

        std.debug.print("   - Ledger {} validated\n", .{new_ledger.sequence});

        // Finalize consensus
        const result = try consensus_engine.finalizeRound();
        std.debug.print("   - Consensus finalized: {s}\n", .{
            if (result.success) "SUCCESS" else "FAILED",
        });

        // Small delay to simulate real timing
        std.time.sleep(100_000_000); // 100ms
    }

    // 5. Show final state
    std.debug.print("\n5. Final ledger state:\n", .{});
    const current = ledger_manager.getCurrentLedger();
    std.debug.print("   Current ledger sequence: {}\n", .{current.sequence});
    std.debug.print("   Total ledgers closed: {}\n", .{num_rounds + 1}); // +1 for genesis
    std.debug.print("   Consensus rounds completed: {}\n", .{num_rounds});
    std.debug.print("   Average time per round: ~100ms (simulated)\n", .{});

    std.debug.print("\n✓ Experimental consensus simulation completed!\n", .{});
    std.debug.print("\nKey observations:\n", .{});
    std.debug.print("  - Each consensus round typically takes 4-5 seconds in production\n", .{});
    std.debug.print("  - No mining required (unlike Bitcoin)\n", .{});
    std.debug.print("  - Byzantine Fault Tolerant with 80% threshold\n", .{});
    std.debug.print("  - Deterministic finality (no chain reorganization)\n", .{});
}
