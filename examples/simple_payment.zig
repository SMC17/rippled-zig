// ============================================================================
// EXPERIMENTAL -- This demo exercises the full node simulation surface
// (ledger state, transaction processing, account management) which is
// outside the v1 toolkit release promise. Kept for research and
// integration testing. For toolkit examples see:
//   examples/encode_transaction.zig
//   examples/sign_and_verify.zig
//   examples/address_encoding.zig
//   examples/rpc_conformance.zig
// ============================================================================
const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const transaction = @import("transaction.zig");
const ledger = @import("ledger.zig");

/// EXPERIMENTAL: Creating, canonically serializing, and signing a simple XRP payment
/// (Depends on node-simulation modules outside the v1 toolkit surface.)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("XRP Ledger Simple Payment Example\n", .{});
    std.debug.print("==================================\n\n", .{});

    // 1. Generate sender key pair
    std.debug.print("1. Generating sender key pair...\n", .{});
    var sender_keys = try crypto.KeyPair.generateEd25519(allocator);
    defer sender_keys.deinit();

    const sender_account_id = sender_keys.getAccountID();
    std.debug.print("   Sender Account ID: {any}\n", .{sender_account_id[0..8]});

    // 2. Generate receiver key pair
    std.debug.print("\n2. Generating receiver key pair...\n", .{});
    var receiver_keys = try crypto.KeyPair.generateEd25519(allocator);
    defer receiver_keys.deinit();

    const receiver_account_id = receiver_keys.getAccountID();
    std.debug.print("   Receiver Account ID: {any}\n", .{receiver_account_id[0..8]});

    // 3. Create account state with some initial balance
    std.debug.print("\n3. Setting up account state...\n", .{});
    var account_state = ledger.AccountState.init(allocator);
    defer account_state.deinit();

    // Create sender account with 1,000,000 XRP
    const sender_account = types.AccountRoot{
        .account = sender_account_id,
        .balance = 1_000_000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    };
    try account_state.putAccount(sender_account);
    std.debug.print("   Sender balance: 1,000,000 XRP\n", .{});

    // 4. Create a payment transaction
    std.debug.print("\n4. Creating payment transaction...\n", .{});
    const payment_amount = types.Amount.fromXRP(100 * types.XRP); // 100 XRP

    var payment = transaction.PaymentTransaction.create(
        sender_account_id,
        receiver_account_id,
        payment_amount,
        types.MIN_TX_FEE,
        1, // sequence
        sender_keys.public_key[0..33].*,
    );
    std.debug.print("   Amount: 100 XRP\n", .{});
    std.debug.print("   Fee: {} drops\n", .{types.MIN_TX_FEE});

    // 5. Serialize canonically
    std.debug.print("\n5. Serializing transaction canonically...\n", .{});
    const serialized = try payment.serialize(allocator);
    defer allocator.free(serialized);
    std.debug.print("   Serialized length: {} bytes\n", .{serialized.len});
    std.debug.print("   Canonical bytes: {s}\n", .{std.fmt.fmtSliceHexLower(serialized)});

    // 6. Sign the transaction
    std.debug.print("\n6. Signing transaction...\n", .{});
    try payment.sign(sender_keys, allocator);
    std.debug.print("   Transaction signed successfully\n", .{});

    // 7. Validate the transaction
    std.debug.print("\n7. Validating transaction...\n", .{});
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const validation_result = try processor.validateTransaction(&payment.base, &account_state);
    std.debug.print("   Validation result: {s}\n", .{@tagName(validation_result)});

    // 8. Submit the transaction
    if (validation_result == .tes_success) {
        std.debug.print("\n8. Submitting transaction...\n", .{});
        try processor.submitTransaction(payment.base);
        std.debug.print("   Transaction submitted to pending queue\n", .{});
        std.debug.print("   Pending transactions: {}\n", .{processor.getPendingTransactions().len});
    }

    std.debug.print("\n✓ Example completed successfully!\n", .{});
    std.debug.print("\nNext steps:\n", .{});
    std.debug.print("  - Canonical bytes can feed signing-hash and fixture tests\n", .{});
    std.debug.print("  - Narrow submit paths can reuse the same serialized form\n", .{});
    std.debug.print("  - Sender balance: {} XRP\n", .{1_000_000 - 100});
    std.debug.print("  - Receiver balance: {} XRP\n", .{100});
}
