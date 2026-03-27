const std = @import("std");
const build_options = @import("build_options");
const crypto = @import("crypto.zig");
const canonical_tx = @import("canonical_tx.zig");
const canonical = @import("canonical.zig");
const base58 = @import("base58.zig");
const types = @import("types.zig");
const serialization = @import("serialization.zig");
const secp256k1_binding = @import("secp256k1_binding.zig");
const secp256k1 = @import("secp256k1.zig");
const ripemd160 = @import("ripemd160.zig");

// Experimental node modules — only imported when -Dexperimental=true
const has_experimental = build_options.experimental;
const consensus = if (has_experimental) @import("consensus.zig") else struct {};
const ledger = @import("ledger.zig");
const network = if (has_experimental) @import("network.zig") else struct {};
const transaction = @import("transaction.zig");
const rpc = @import("rpc.zig");
const storage = if (has_experimental) @import("storage.zig") else struct {};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "encode-tx")) {
        try cmdEncodeTx(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "hash-tx")) {
        try cmdHashTx(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "verify-sig")) {
        try cmdVerifySig(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "encode-address")) {
        try cmdEncodeAddress(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "version")) {
        printVersion();
    } else if (std.mem.eql(u8, command, "help")) {
        printUsage();
    } else if (has_experimental and std.mem.eql(u8, command, "node")) {
        try cmdNodeRun(allocator);
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}

fn printVersion() void {
    std.debug.print("rippled-zig v1.0.0\n", .{});
    std.debug.print("XRPL Protocol Toolkit — canonical encoding, signing, verification\n", .{});
    std.debug.print("Zig {s} | ", .{@import("builtin").zig_version_string});
    if (build_options.has_secp256k1) {
        std.debug.print("secp256k1: linked", .{});
    } else {
        std.debug.print("secp256k1: stub", .{});
    }
    if (has_experimental) {
        std.debug.print(" | experimental: enabled", .{});
    }
    std.debug.print("\n", .{});
}

fn printUsage() void {
    std.debug.print(
        \\rippled-zig — XRPL Protocol Toolkit
        \\
        \\USAGE:
        \\  rippled-zig <command> [options]
        \\
        \\COMMANDS:
        \\  encode-tx       Encode a transaction in canonical XRPL binary format
        \\  hash-tx         Compute signing hash for a transaction
        \\  verify-sig      Verify a transaction signature
        \\  encode-address  Encode/decode XRPL base58check addresses
        \\  version         Show version and build info
        \\  help            Show this help
        \\
    , .{});
    if (has_experimental) {
        std.debug.print(
            \\EXPERIMENTAL:
            \\  node            Run experimental local node runtime
            \\
        , .{});
    }
}

/// encode-tx: Encode a Payment transaction from CLI args
fn cmdEncodeTx(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 4) {
        std.debug.print(
            \\Usage: rippled-zig encode-tx <account> <destination> <amount_drops> [fee_drops] [sequence]
            \\
            \\Example:
            \\  rippled-zig encode-tx rN7n7otQDd6FczFgLdlqtyMVrn3X66B4T rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh 1000000 10 1
            \\
        , .{});
        return;
    }

    const account = args[0];
    const destination = args[1];
    const amount = args[2];
    const fee = if (args.len > 3) args[3] else "10";
    const sequence = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else @as(u32, 1);

    var ser = try canonical_tx.CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();

    const tx_json = canonical_tx.TransactionJSON{
        .TransactionType = "Payment",
        .Account = account,
        .Destination = destination,
        .Amount = amount,
        .Fee = fee,
        .Sequence = sequence,
        .Flags = 2147483648, // tfFullyCanonicalSig
    };

    const serialized = try ser.serializeForSigning(tx_json);
    defer allocator.free(serialized);

    // Output hex-encoded bytes
    const stdout = std.io.getStdOut().writer();
    try stdout.print("canonical_bytes: ", .{});
    for (serialized) |byte| {
        try stdout.print("{x:0>2}", .{byte});
    }
    try stdout.print("\nbyte_length: {d}\n", .{serialized.len});

    // Also compute and show the signing hash
    const hash = canonical_tx.CanonicalTransactionSerializer.calculateBodyHash(serialized);
    try stdout.print("body_hash: ", .{});
    for (hash) |byte| {
        try stdout.print("{x:0>2}", .{byte});
    }
    try stdout.print("\n", .{});
}

/// hash-tx: Compute signing hash from hex-encoded canonical bytes
fn cmdHashTx(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print(
            \\Usage: rippled-zig hash-tx <hex_bytes>
            \\
            \\Computes the SHA-512 Half signing hash of canonical transaction bytes.
            \\
            \\Example:
            \\  rippled-zig hash-tx 12000022800000002400000001614000000000...
            \\
        , .{});
        return;
    }

    const hex_input = args[0];
    if (hex_input.len % 2 != 0) {
        std.debug.print("Error: hex input must have even length\n", .{});
        return;
    }

    const bytes = try allocator.alloc(u8, hex_input.len / 2);
    defer allocator.free(bytes);

    for (0..bytes.len) |i| {
        bytes[i] = std.fmt.parseInt(u8, hex_input[i * 2 .. i * 2 + 2], 16) catch {
            std.debug.print("Error: invalid hex at position {d}\n", .{i * 2});
            return;
        };
    }

    const hash = crypto.Hash.sha512Half(bytes);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("signing_hash: ", .{});
    for (hash) |byte| {
        try stdout.print("{x:0>2}", .{byte});
    }
    try stdout.print("\n", .{});
}

/// verify-sig: Verify a secp256k1 signature
fn cmdVerifySig(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    if (args.len < 3) {
        std.debug.print(
            \\Usage: rippled-zig verify-sig <hash_hex> <signature_hex> <pubkey_hex>
            \\
            \\Verifies a secp256k1 ECDSA signature against a transaction hash.
            \\
            \\Example:
            \\  rippled-zig verify-sig <32-byte-hash> <DER-signature> <33-byte-pubkey>
            \\
        , .{});
        return;
    }

    const hash_hex = args[0];
    const sig_hex = args[1];
    const pubkey_hex = args[2];

    if (hash_hex.len != 64) {
        std.debug.print("Error: hash must be 32 bytes (64 hex chars)\n", .{});
        return;
    }

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        hash[i] = std.fmt.parseInt(u8, hash_hex[i * 2 .. i * 2 + 2], 16) catch {
            std.debug.print("Error: invalid hash hex\n", .{});
            return;
        };
    }

    // Parse DER signature from hex
    if (sig_hex.len % 2 != 0 or sig_hex.len < 16) {
        std.debug.print("Error: invalid signature hex\n", .{});
        return;
    }
    var sig_bytes: [72]u8 = undefined;
    const sig_len = sig_hex.len / 2;
    if (sig_len > 72) {
        std.debug.print("Error: signature too long\n", .{});
        return;
    }
    for (0..sig_len) |i| {
        sig_bytes[i] = std.fmt.parseInt(u8, sig_hex[i * 2 .. i * 2 + 2], 16) catch {
            std.debug.print("Error: invalid signature hex\n", .{});
            return;
        };
    }

    // Parse pubkey from hex
    if (pubkey_hex.len != 66) {
        std.debug.print("Error: pubkey must be 33 bytes (66 hex chars)\n", .{});
        return;
    }
    var pubkey_bytes: [33]u8 = undefined;
    for (0..33) |i| {
        pubkey_bytes[i] = std.fmt.parseInt(u8, pubkey_hex[i * 2 .. i * 2 + 2], 16) catch {
            std.debug.print("Error: invalid pubkey hex\n", .{});
            return;
        };
    }

    // Verify using secp256k1 binding
    const result = secp256k1_binding.verifySignature(&pubkey_bytes, hash, sig_bytes[0..sig_len]) catch |err| {
        std.debug.print("Error: verification failed: {s}\n", .{@errorName(err)});
        return;
    };
    const stdout = std.io.getStdOut().writer();
    try stdout.print("valid: {}\n", .{result});
}

/// encode-address: Base58Check encode/decode
fn cmdEncodeAddress(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print(
            \\Usage: rippled-zig encode-address <hex_account_id>
            \\       rippled-zig encode-address --decode <base58_address>
            \\
            \\Encode a 20-byte account ID to XRPL base58check, or decode back.
            \\
        , .{});
        return;
    }

    if (std.mem.eql(u8, args[0], "--decode") and args.len > 1) {
        const decoded = try base58.Base58.decodeAccountID(allocator, args[1]);
        const stdout = std.io.getStdOut().writer();
        try stdout.print("account_id: ", .{});
        for (decoded) |byte| {
            try stdout.print("{x:0>2}", .{byte});
        }
        try stdout.print("\n", .{});
    } else {
        const hex = args[0];
        if (hex.len != 40) {
            std.debug.print("Error: account ID must be 20 bytes (40 hex chars)\n", .{});
            return;
        }
        var account_id: [20]u8 = undefined;
        for (0..20) |i| {
            account_id[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch {
                std.debug.print("Error: invalid hex\n", .{});
                return;
            };
        }
        const encoded = try base58.Base58.encodeAccountID(allocator, account_id);
        defer allocator.free(encoded);
        const stdout = std.io.getStdOut().writer();
        try stdout.print("address: {s}\n", .{encoded});
    }
}

/// Experimental: run full node runtime
fn cmdNodeRun(allocator: std.mem.Allocator) !void {
    if (!has_experimental) {
        std.debug.print("Error: node mode requires -Dexperimental=true build flag\n", .{});
        return;
    }

    std.debug.print("rippled-zig Experimental Node Runtime\n", .{});
    std.debug.print("=====================================\n\n", .{});

    var ledger_manager = try ledger.LedgerManager.init(allocator);
    defer ledger_manager.deinit();

    var account_state = ledger.AccountState.init(allocator);
    defer account_state.deinit();

    var tx_processor = try transaction.TransactionProcessor.init(allocator);
    defer tx_processor.deinit();

    var rpc_server = rpc.RpcServer.init(allocator, 5005, &ledger_manager, &account_state, &tx_processor);
    defer rpc_server.deinit();

    std.debug.print("Node initialized\n", .{});
    std.debug.print("Current ledger: #{d}\n", .{ledger_manager.getCurrentLedger().sequence});
    std.debug.print("\nExperimental — not for production use\n", .{});
}

// ── Tests ──

test "basic toolkit imports" {
    _ = crypto;
    _ = canonical_tx;
    _ = base58;
    _ = types;
    _ = serialization;
    _ = ripemd160;
}

test "version string" {
    printVersion();
}

// Import all test suites
comptime {
    _ = @import("crypto.zig");
    _ = @import("types.zig");
    _ = @import("base58.zig");
    _ = @import("canonical_tx.zig");
    _ = @import("canonical.zig");
    _ = @import("serialization.zig");
    _ = @import("ripemd160.zig");
    _ = @import("secp256k1_binding.zig");
    _ = @import("secp256k1.zig");
    _ = @import("transaction.zig");
    _ = @import("ledger.zig");
    _ = @import("rpc.zig");
    _ = @import("rpc_methods.zig");
    _ = @import("invariants.zig");
    _ = @import("invariant_probe.zig");
    _ = @import("determinism_check.zig");
    _ = @import("parity_check.zig");
    _ = @import("merkle.zig");
    _ = @import("amendments.zig");

    // Experimental test suites
    if (has_experimental) {
        _ = @import("consensus.zig");
        _ = @import("network.zig");
        _ = @import("peer_protocol.zig");
        _ = @import("peer_wire.zig");
        _ = @import("websocket.zig");
        _ = @import("dex.zig");
        _ = @import("nft.zig");
        _ = @import("checks.zig");
        _ = @import("escrow.zig");
        _ = @import("payment_channels.zig");
        _ = @import("validators.zig");
        _ = @import("metrics.zig");
        _ = @import("security.zig");
        _ = @import("storage.zig");
        _ = @import("database.zig");
        _ = @import("ledger_sync.zig");
        _ = @import("overlay_https.zig");
        _ = @import("remaining_transactions.zig");
    }
}
