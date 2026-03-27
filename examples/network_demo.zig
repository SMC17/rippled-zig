// ============================================================================
// EXPERIMENTAL -- This demo exercises the P2P networking module, which is
// outside the v1 toolkit release promise. Kept for research and integration
// testing. For toolkit examples see:
//   examples/encode_transaction.zig
//   examples/sign_and_verify.zig
//   examples/address_encoding.zig
//   examples/rpc_conformance.zig
// ============================================================================
const std = @import("std");
const network = @import("network.zig");

/// EXPERIMENTAL: Demo of the in-repo P2P networking module
/// (Depends on node-simulation modules outside the v1 toolkit surface.)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Experimental P2P Network Demo ===\n\n", .{});

    // Create network instance
    var net = try network.Network.init(allocator, 51235);
    defer net.deinit();

    std.debug.print("Network created on port 51235\n", .{});

    // Test message serialization
    const ping_msg = network.Message.ping();
    const serialized = try ping_msg.serialize(allocator);
    defer allocator.free(serialized);

    std.debug.print("Serialized ping message: {d} bytes\n", .{serialized.len});

    const deserialized = try network.Message.deserialize(serialized, allocator);
    defer allocator.free(deserialized.payload);

    std.debug.print("Deserialized successfully: type={s}\n\n", .{@tagName(deserialized.msg_type)});

    // Test custom message
    const test_message = network.Message{
        .msg_type = .transaction,
        .payload = "test transaction data",
    };

    const test_serialized = try test_message.serialize(allocator);
    defer allocator.free(test_serialized);

    std.debug.print("Custom message serialized: {d} bytes\n", .{test_serialized.len});

    const test_deserialized = try network.Message.deserialize(test_serialized, allocator);
    defer allocator.free(test_deserialized.payload);

    std.debug.print("Custom message payload: {s}\n\n", .{test_deserialized.payload});

    std.debug.print("=== Network Features ===\n", .{});
    std.debug.print("✅ TCP listener (implemented)\n", .{});
    std.debug.print("✅ Message serialization (implemented)\n", .{});
    std.debug.print("✅ Peer connections (implemented)\n", .{});
    std.debug.print("✅ Message broadcasting (implemented)\n\n", .{});

    std.debug.print("To start a listening server:\n", .{});
    std.debug.print("  net.listen() - starts TCP listener\n", .{});
    std.debug.print("  net.connectPeer(\"127.0.0.1\", 51235) - connect to peer\n", .{});
    std.debug.print("  net.broadcast(message) - broadcast to all peers\n\n", .{});

    std.debug.print("This demo is outside the current v1 toolkit release promise.\n", .{});
    std.debug.print("Demo complete!\n", .{});
}
