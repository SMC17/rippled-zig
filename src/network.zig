const std = @import("std");
const peer_protocol = @import("peer_protocol.zig");

/// Peer-to-peer networking for XRPL nodes
pub const Network = struct {
    allocator: std.mem.Allocator,
    peers: std.ArrayList(Peer),
    listen_port: u16,
    server: ?std.net.Server,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, port: u16) !Network {
        return Network{
            .allocator = allocator,
            .peers = try std.ArrayList(Peer).initCapacity(allocator, 0),
            .listen_port = port,
            .server = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Network) void {
        self.stop();
        self.peers.deinit(self.allocator);
    }

    /// Start listening for peer connections
    pub fn listen(self: *Network) !void {
        const address = try std.net.Address.parseIp("127.0.0.1", self.listen_port);

        var server = try address.listen(.{
            .reuse_address = true,
            .reuse_port = true,
        });

        self.server = server;
        self.running.store(true, .seq_cst);

        std.debug.print("Network listening on port {d}\n", .{self.listen_port});

        // Accept connections in a loop
        while (self.running.load(.seq_cst)) {
            // Set a timeout so we can check running flag
            var connection = server.accept() catch |err| switch (err) {
                error.ConnectionResetByPeer => continue,
                error.ConnectionAborted => continue,
                else => return err,
            };

            // Handle connection (for now, just log and close)
            std.debug.print("Accepted connection from {}\n", .{connection.address});
            connection.stream.close();
        }
    }

    /// Stop the network listener
    pub fn stop(self: *Network) void {
        self.running.store(false, .seq_cst);
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
    }

    /// Connect to a peer with handshake
    pub fn connectPeer(self: *Network, address: []const u8, port: u16, node_id: [32]u8, network_id: u32) !*Peer {
        // Use tcpConnectToHost for hostname resolution; overlay_https for XRPL/2.0 upgrade when needed
        const stream = std.net.tcpConnectToHost(self.allocator, address, port) catch blk: {
            const addr = std.net.Address.parseIp(address, port) catch return error.ConnectionFailed;
            break :blk try std.net.tcpConnectToAddress(addr);
        };

        // Perform handshake
        const peer_proto = @import("peer_protocol.zig");
        var protocol = peer_proto.PeerProtocol.init(self.allocator, node_id, network_id);
        const handshake_result = protocol.handshake(&stream) catch |err| {
            stream.close();
            return err;
        };

        const peer = Peer{
            .node_id = handshake_result.peer_id,
            .address = try self.allocator.dupe(u8, address),
            .port = port,
            .public_key = [_]u8{0} ** 33,
            .connected = true,
            .stream = stream,
            .allocator = self.allocator,
        };

        try self.peers.append(self.allocator, peer);
        std.debug.print("Connected to peer {}:{d} (ledger: {d})\n", .{ std.fmt.fmtSliceHexLower(address[0..@min(8, address.len)]), port, handshake_result.peer_ledger_seq });

        return &self.peers.items[self.peers.items.len - 1];
    }

    /// Broadcast a message to all peers
    pub fn broadcast(self: *Network, message: Message) !void {
        for (self.peers.items) |*peer| {
            peer.send(message) catch |err| {
                std.debug.print("Failed to send to peer: {}\n", .{err});
                continue;
            };
        }
    }

    /// Process incoming messages from all peers, dispatching to handler.
    /// Runs one round; for continuous dispatch run in a loop/thread.
    pub fn processIncoming(self: *Network, handler: *const fn (MessageType, []const u8) void) void {
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            const msg = peer.receive(self.allocator) catch |err| {
                if (err == error.ConnectionClosed) peer.connected = false;
                continue;
            };
            defer self.allocator.free(msg.payload);
            handler(msg.msg_type, msg.payload);
        }
    }

    /// Get connected peer count
    pub fn getPeerCount(self: *const Network) usize {
        var count: usize = 0;
        for (self.peers.items) |peer| {
            if (peer.connected) count += 1;
        }
        return count;
    }

    /// Connect to testnet peer (s.altnet.rippletest.net:51235)
    /// Note: Real rippled uses XRPL/2.0 over HTTPS; our custom protocol may not interconnect.
    pub fn connectToTestnet(self: *Network, node_id: [32]u8, network_id: u32) ?*Peer {
        return self.connectPeer("s.altnet.rippletest.net", 51235, node_id, network_id) catch |err| {
            std.debug.print("[WARN] Testnet connect failed: {}\n", .{err});
            return null;
        };
    }
};

/// A connected peer node
pub const Peer = struct {
    node_id: [32]u8,
    address: []const u8,
    port: u16,
    public_key: [33]u8,
    connected: bool,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Peer) void {
        self.stream.close();
        self.allocator.free(self.address);
    }

    /// Send a message to this peer
    pub fn send(self: *Peer, message: Message) !void {
        if (!self.connected) return error.NotConnected;

        const serialized = try message.serialize(self.allocator);
        defer self.allocator.free(serialized);

        _ = try self.stream.write(serialized);
    }

    /// Receive a message from this peer
    pub fn receive(self: *Peer, allocator: std.mem.Allocator) !Message {
        if (!self.connected) return error.NotConnected;

        var buffer: [4096]u8 = undefined;
        const bytes_read = try self.stream.read(&buffer);

        if (bytes_read == 0) {
            self.connected = false;
            return error.ConnectionClosed;
        }

        return try Message.deserialize(buffer[0..bytes_read], allocator);
    }
};

/// Message types exchanged between peers
pub const MessageType = enum(u8) {
    ping = 1,
    pong = 2,
    transaction = 3,
    get_ledger = 4,
    ledger_data = 5,
    proposal = 6,
    validation = 7,
    get_objects = 8,
    get_peers = 9,
};

/// Network message structure
pub const Message = struct {
    msg_type: MessageType,
    payload: []const u8,

    /// Create a ping message
    pub fn ping() Message {
        return Message{
            .msg_type = .ping,
            .payload = &[_]u8{},
        };
    }

    /// Create a pong message
    pub fn pong() Message {
        return Message{
            .msg_type = .pong,
            .payload = &[_]u8{},
        };
    }

    /// Serialize message for transmission
    pub fn serialize(self: Message, allocator: std.mem.Allocator) ![]u8 {
        // Simple format: [type:1byte][length:4bytes][payload]
        const total_len = 1 + 4 + self.payload.len;
        var buffer = try allocator.alloc(u8, total_len);

        buffer[0] = @intFromEnum(self.msg_type);
        std.mem.writeInt(u32, buffer[1..5], @intCast(self.payload.len), .big);
        @memcpy(buffer[5..], self.payload);

        return buffer;
    }

    /// Deserialize message from bytes
    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !Message {
        if (data.len < 5) return error.InvalidMessage;

        const msg_type = std.meta.intToEnum(MessageType, data[0]) catch return error.InvalidMessageType;
        const payload_len = std.mem.readInt(u32, data[1..5][0..4], .big);

        if (data.len < 5 + payload_len) return error.TruncatedMessage;

        const payload = try allocator.dupe(u8, data[5 .. 5 + payload_len]);

        return Message{
            .msg_type = msg_type,
            .payload = payload,
        };
    }
};

test "network initialization" {
    const allocator = std.testing.allocator;
    var network = try Network.init(allocator, 51235);
    defer network.deinit();

    try std.testing.expectEqual(@as(u16, 51235), network.listen_port);
    try std.testing.expectEqual(@as(usize, 0), network.peers.items.len);
    try std.testing.expect(!network.running.load(.seq_cst));
}

test "message serialization" {
    const allocator = std.testing.allocator;

    const msg = Message.ping();
    const serialized = try msg.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expectEqual(@as(u8, 1), serialized[0]); // ping = 1
    try std.testing.expectEqual(@as(usize, 5), serialized.len); // 1 + 4 + 0
}

test "message round-trip" {
    const allocator = std.testing.allocator;

    const original = Message{
        .msg_type = .transaction,
        .payload = "test payload",
    };

    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized = try Message.deserialize(serialized, allocator);
    defer allocator.free(deserialized.payload);

    try std.testing.expectEqual(original.msg_type, deserialized.msg_type);
    try std.testing.expectEqualStrings(original.payload, deserialized.payload);
}
