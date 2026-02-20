const std = @import("std");
const types = @import("types.zig");
const network = @import("network.zig");
const crypto = @import("crypto.zig");
const overlay_https = @import("overlay_https.zig");

/// Complete XRPL Peer Protocol Implementation
///
/// WEEK 3: Full peer-to-peer protocol for network joining
///
/// XRPL uses Protocol Buffers for peer messages, but we implement
/// a binary format compatible with the essential message types
pub const PeerProtocol = struct {
    allocator: std.mem.Allocator,
    node_id: [32]u8,
    network_id: u32, // 0 = mainnet, 1 = testnet
    protocol_version: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, node_id: [32]u8, network_id: u32) PeerProtocol {
        return PeerProtocol{
            .allocator = allocator,
            .node_id = node_id,
            .network_id = network_id,
            .protocol_version = 1,
        };
    }

    /// Perform peer handshake - XRPL handshake protocol (accepts *PeerStream or *std.net.Stream)
    pub fn handshake(self: *PeerProtocol, stream: anytype) !HandshakeResult {
        // XRPL peer handshake:
        // 1. Send Hello message with our node ID, network ID, and capabilities
        // 2. Receive Hello from peer
        // 3. Validate peer's network ID matches
        // 4. Exchange ledger state (current ledger sequence)

        const hello = try self.createHelloMessage();
        defer self.allocator.free(hello);

        // Send Hello with 4-byte length prefix
        var hello_with_len = try std.ArrayList(u8).initCapacity(self.allocator, hello.len + 4);
        defer hello_with_len.deinit();

        std.mem.writeInt(u32, try hello_with_len.addManyAsSlice(4), @intCast(hello.len), .big);
        try hello_with_len.appendSlice(hello);

        _ = try stream.write(hello_with_len.items);

        // Receive peer's hello (with length prefix)
        var len_buffer: [4]u8 = undefined;
        const len_bytes = try stream.readAll(&len_buffer);
        if (len_bytes != 4) return error.InvalidHandshake;

        const peer_hello_len = std.mem.readInt(u32, &len_buffer, .big);
        if (peer_hello_len > 4096) return error.InvalidHandshake;

        var hello_buffer: [4096]u8 = undefined;
        const hello_bytes = try stream.readAll(hello_buffer[0..peer_hello_len]);
        if (hello_bytes != peer_hello_len) return error.InvalidHandshake;

        const peer_hello = try self.parseHelloMessage(hello_buffer[0..peer_hello_len]);

        // Validate network ID matches
        if (peer_hello.network_id != self.network_id) {
            return error.NetworkMismatch;
        }

        return HandshakeResult{
            .peer_id = peer_hello.node_id,
            .peer_ledger_seq = peer_hello.ledger_sequence,
            .peer_ledger_hash = peer_hello.ledger_hash,
            .success = true,
        };
    }

    /// Create Hello message (XRPL format)
    fn createHelloMessage(self: *PeerProtocol) ![]u8 {
        // XRPL Hello message format (simplified binary):
        // [protocol_version:4][network_id:4][node_id:32][ledger_seq:4][ledger_hash:32][app_name_len:1][app_name]

        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 100);
        errdefer buffer.deinit();

        // Protocol version
        try buffer.writer().writeInt(u32, self.protocol_version, .big);

        // Network ID
        try buffer.writer().writeInt(u32, self.network_id, .big);

        // Node ID (32 bytes)
        try buffer.appendSlice(&self.node_id);

        // Current ledger sequence (placeholder - would get from ledger manager)
        try buffer.writer().writeInt(u32, 0, .big);

        // Current ledger hash (placeholder)
        var zero_hash: [32]u8 = [_]u8{0} ** 32;
        try buffer.appendSlice(&zero_hash);

        // App name: "rippled-zig"
        const app_name = "rippled-zig";
        try buffer.append(@intCast(app_name.len));
        try buffer.appendSlice(app_name);

        return buffer.toOwnedSlice();
    }

    /// Parse Hello message from peer
    fn parseHelloMessage(self: *PeerProtocol, data: []const u8) !PeerHello {
        _ = self;

        if (data.len < 77) return error.InvalidMessage; // Minimum size

        var offset: usize = 0;

        // Protocol version
        const protocol_version = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // Network ID
        const network_id = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // Node ID (32 bytes)
        var node_id: [32]u8 = undefined;
        @memcpy(&node_id, data[offset..][0..32]);
        offset += 32;

        // Ledger sequence
        const ledger_sequence = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // Ledger hash (32 bytes)
        var ledger_hash: [32]u8 = undefined;
        @memcpy(&ledger_hash, data[offset..][0..32]);
        offset += 32;

        // App name (if present)
        if (offset < data.len) {
            const app_name_len = data[offset];
            _ = app_name_len;
            offset += 1;
            // Skip app name for now
        }

        return PeerHello{
            .protocol_version = protocol_version,
            .network_id = network_id,
            .node_id = node_id,
            .ledger_sequence = ledger_sequence,
            .ledger_hash = ledger_hash,
        };
    }

    /// Request ledger from peer (accepts *PeerStream or *std.net.Stream)
    pub fn requestLedger(self: *PeerProtocol, stream: anytype, ledger_seq: types.LedgerSequence, ledger_hash: ?types.LedgerHash) !void {
        // XRPL GetLedger message format:
        // [type:1][ledger_seq:4][ledger_hash:32?]

        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 40);
        defer buffer.deinit();

        // Message type: GetLedger (4)
        try buffer.append(4);

        // Ledger sequence
        var seq_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &seq_bytes, ledger_seq, .big);
        try buffer.appendSlice(&seq_bytes);

        // Optional ledger hash
        if (ledger_hash) |hash| {
            try buffer.appendSlice(&hash);
        }

        // Send with length prefix
        var msg_with_len = try std.ArrayList(u8).initCapacity(self.allocator, buffer.items.len + 4);
        defer msg_with_len.deinit();

        std.mem.writeInt(u32, try msg_with_len.addManyAsSlice(4), @intCast(buffer.items.len), .big);
        try msg_with_len.appendSlice(buffer.items);

        _ = try stream.write(msg_with_len.items);
    }

    /// Send transaction to peer (for flooding; accepts *PeerStream or *std.net.Stream)
    pub fn sendTransaction(self: *PeerProtocol, stream: anytype, tx_data: []const u8) !void {
        // Transaction message format: [type:1][tx_data]

        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, tx_data.len + 1);
        defer buffer.deinit();

        // Message type: Transaction (3)
        try buffer.append(3);
        try buffer.appendSlice(tx_data);

        // Send with length prefix
        var msg_with_len = try std.ArrayList(u8).initCapacity(self.allocator, buffer.items.len + 4);
        defer msg_with_len.deinit();

        std.mem.writeInt(u32, try msg_with_len.addManyAsSlice(4), @intCast(buffer.items.len), .big);
        try msg_with_len.appendSlice(buffer.items);

        _ = try stream.write(msg_with_len.items);
    }

    /// Receive message from peer (accepts *PeerStream or *std.net.Stream)
    pub fn receiveMessage(self: *PeerProtocol, stream: anytype) !PeerMessage {
        // Read length prefix
        var len_buffer: [4]u8 = undefined;
        const len_bytes = try stream.readAll(&len_buffer);
        if (len_bytes != 4) return error.ConnectionClosed;

        const msg_len = std.mem.readInt(u32, &len_buffer, .big);
        if (msg_len > 1024 * 1024) return error.MessageTooLarge; // 1MB max

        // Read message data
        var msg_buffer = try self.allocator.alloc(u8, msg_len);
        errdefer self.allocator.free(msg_buffer);

        const bytes_read = try stream.readAll(msg_buffer);
        if (bytes_read != msg_len) {
            self.allocator.free(msg_buffer);
            return error.TruncatedMessage;
        }

        if (msg_len == 0) {
            self.allocator.free(msg_buffer);
            return error.InvalidMessage;
        }

        const msg_type = msg_buffer[0];
        _ = msg_buffer[1..]; // payload available but not used in struct

        return PeerMessage{
            .msg_type = msg_type,
            .payload = msg_buffer,
            .allocator = self.allocator,
        };
    }

    /// Broadcast transaction to peers
    pub fn broadcastTransaction(self: *PeerProtocol, tx_data: []const u8, peers: []network.Peer) !void {
        for (peers) |*peer| {
            if (!peer.connected) continue;

            self.sendTransaction(&peer.stream, tx_data) catch |err| {
                std.debug.print("[WARN] Failed to broadcast to peer {}: {}\n", .{ peer.address, err });
                peer.connected = false;
                continue;
            };
        }
    }
};

pub const HandshakeResult = struct {
    peer_id: [32]u8,
    peer_ledger_seq: types.LedgerSequence,
    peer_ledger_hash: types.LedgerHash,
    success: bool,
};

pub const PeerHello = struct {
    protocol_version: u32,
    network_id: u32,
    node_id: [32]u8,
    ledger_sequence: types.LedgerSequence,
    ledger_hash: types.LedgerHash,
};

pub const PeerMessage = struct {
    msg_type: u8,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PeerMessage) void {
        self.allocator.free(self.payload);
    }
};

/// Peer Connection Manager - handles connection lifecycle
pub const PeerConnection = struct {
    allocator: std.mem.Allocator,
    stream: overlay_https.PeerStream,
    protocol: PeerProtocol,
    connected: bool,
    last_ping: i64,

    pub fn init(allocator: std.mem.Allocator, stream: overlay_https.PeerStream, node_id: [32]u8, network_id: u32) PeerConnection {
        return PeerConnection{
            .allocator = allocator,
            .stream = stream,
            .protocol = PeerProtocol.init(allocator, node_id, network_id),
            .connected = true,
            .last_ping = 0,
        };
    }

    pub fn deinit(self: *PeerConnection) void {
        self.stream.close();
    }

    /// Perform handshake
    pub fn connect(self: *PeerConnection) !HandshakeResult {
        return self.protocol.handshake(&self.stream);
    }

    /// Send ping (keep-alive)
    pub fn ping(self: *PeerConnection) !void {
        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 5);
        defer buffer.deinit();

        buffer.append(1) catch unreachable; // Ping type
        std.mem.writeInt(u32, try buffer.addManyAsSlice(4), 0, .big);

        var msg_with_len = try std.ArrayList(u8).initCapacity(self.allocator, buffer.items.len + 4);
        defer msg_with_len.deinit();

        std.mem.writeInt(u32, try msg_with_len.addManyAsSlice(4), @intCast(buffer.items.len), .big);
        try msg_with_len.appendSlice(buffer.items);

        try self.stream.write(msg_with_len.items);
        self.last_ping = std.time.timestamp();
    }

    /// Receive and handle messages
    pub fn handleMessages(self: *PeerConnection) !void {
        while (self.connected) {
            const msg = self.protocol.receiveMessage(&self.stream) catch |err| {
                if (err == error.ConnectionClosed) {
                    self.connected = false;
                    break;
                }
                return err;
            };
            defer msg.deinit();

            switch (msg.msg_type) {
                1 => { // Ping
                    // Respond with pong
                    var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 1);
                    defer buffer.deinit();
                    buffer.append(2) catch unreachable; // Pong type

                    var msg_with_len = try std.ArrayList(u8).initCapacity(self.allocator, buffer.items.len + 4);
                    defer msg_with_len.deinit();

                    std.mem.writeInt(u32, try msg_with_len.addManyAsSlice(4), @intCast(buffer.items.len), .big);
                    try msg_with_len.appendSlice(buffer.items);

                    _ = self.stream.write(msg_with_len.items) catch |err| {
                        std.debug.print("[WARN] Failed to send pong: {}\n", .{err});
                    };
                },
                3 => { // Transaction
                    // Handle transaction flooding
                    std.debug.print("[INFO] Received transaction from peer\n", .{});
                },
                4 => { // GetLedger
                    std.debug.print("[INFO] Received ledger request from peer\n", .{});
                },
                5 => { // LedgerData
                    std.debug.print("[INFO] Received ledger data from peer\n", .{});
                },
                else => {
                    std.debug.print("[WARN] Unknown message type: {d}\n", .{msg.msg_type});
                },
            }
        }
    }
};

/// Peer Discovery - Find and connect to XRPL nodes
pub const PeerDiscovery = struct {
    allocator: std.mem.Allocator,
    known_peers: std.ArrayList(PeerAddress),

    pub fn init(allocator: std.mem.Allocator) !PeerDiscovery {
        var discovery = PeerDiscovery{
            .allocator = allocator,
            .known_peers = try std.ArrayList(PeerAddress).initCapacity(allocator, 10),
        };

        // Add default testnet peers
        try discovery.addDefaultPeers();

        return discovery;
    }

    pub fn deinit(self: *PeerDiscovery) void {
        for (self.known_peers.items) |*peer| {
            self.allocator.free(peer.hostname);
        }
        self.known_peers.deinit(self.allocator);
    }

    fn addDefaultPeers(self: *PeerDiscovery) !void {
        // XRPL Altnet (testnet) peers
        const testnet_peers = [_]struct { host: []const u8, port: u16 }{
            .{ .host = "s.altnet.rippletest.net", .port = 51235 },
            .{ .host = "s1.altnet.rippletest.net", .port = 51235 },
            .{ .host = "s2.altnet.rippletest.net", .port = 51235 },
        };

        for (testnet_peers) |peer_info| {
            const peer = PeerAddress{
                .hostname = try self.allocator.dupe(u8, peer_info.host),
                .port = peer_info.port,
                .network_id = 1, // Testnet
            };
            try self.known_peers.append(self.allocator, peer);
        }
    }

    /// Get peers for connection
    pub fn getPeers(self: *const PeerDiscovery) []const PeerAddress {
        return self.known_peers.items;
    }

    /// Connect to a peer (tries overlay HTTP upgrade first for XRPL/2.0 compat)
    pub fn connectToPeer(self: *PeerDiscovery, node_id: [32]u8, network_id: u32) !?PeerConnection {
        const peers = self.getPeers();
        if (peers.len == 0) return null;

        const peer_addr = peers[0];

        const peer_stream = blk: {
            // Try TLS+upgrade first (real rippled), then plain upgrade (rippled-zig), then raw TCP
            if (overlay_https.connectWithTlsAndUpgrade(self.allocator, peer_addr.hostname, peer_addr.port)) |tls| {
                break :blk overlay_https.PeerStream{ .tls = tls };
            } else |_| {}

            const upgrade = overlay_https.connectWithUpgrade(self.allocator, peer_addr.hostname, peer_addr.port) catch |err| {
                if (err == error.UpgradeRejected or err == error.ConnectionClosed) {
                    const raw = std.net.tcpConnectToHost(self.allocator, peer_addr.hostname, peer_addr.port) catch return null;
                    break :blk overlay_https.PeerStream{ .raw = raw };
                }
                return null;
            };
            break :blk overlay_https.PeerStream{ .raw = upgrade };
        };

        var connection = PeerConnection.init(self.allocator, peer_stream, node_id, network_id);

        // Perform handshake
        const handshake_result = connection.connect() catch |err| {
            std.debug.print("[WARN] Handshake failed with {}: {}\n", .{ peer_addr.hostname, err });
            connection.deinit();
            return null;
        };

        std.debug.print("[INFO] Connected to peer {} (ledger: {d})\n", .{ peer_addr.hostname, handshake_result.peer_ledger_seq });

        return connection;
    }
};

pub const PeerAddress = struct {
    hostname: []const u8,
    port: u16,
    network_id: u32,
};

test "peer protocol handshake" {
    const allocator = std.testing.allocator;
    const node_id = [_]u8{1} ** 32;

    var protocol = PeerProtocol.init(allocator, node_id, 1);

    const hello = try protocol.createHelloMessage();
    defer allocator.free(hello);

    try std.testing.expect(hello.len >= 77); // Minimum Hello size

    // Parse it back
    const parsed = try protocol.parseHelloMessage(hello);
    try std.testing.expectEqual(@as(u32, 1), parsed.protocol_version);
    try std.testing.expectEqual(@as(u32, 1), parsed.network_id);
}

test "peer discovery" {
    const allocator = std.testing.allocator;
    var discovery = try PeerDiscovery.init(allocator);
    defer discovery.deinit();

    const peers = discovery.getPeers();
    try std.testing.expect(peers.len >= 3); // Should have default testnet peers

    std.debug.print("[INFO] Default testnet peers: {d}\n", .{peers.len});
}
