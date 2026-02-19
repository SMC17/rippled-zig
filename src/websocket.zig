const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");

/// WebSocket server for real-time subscriptions
pub const WebSocketServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    clients: std.ArrayList(WebSocketClient),
    server: ?std.net.Server,
    running: std.atomic.Value(bool),
    ledger_manager: *ledger.LedgerManager,

    pub fn init(allocator: std.mem.Allocator, port: u16, ledger_manager: *ledger.LedgerManager) !WebSocketServer {
        return WebSocketServer{
            .allocator = allocator,
            .port = port,
            .clients = try std.ArrayList(WebSocketClient).initCapacity(allocator, 0),
            .server = null,
            .running = std.atomic.Value(bool).init(false),
            .ledger_manager = ledger_manager,
        };
    }

    pub fn deinit(self: *WebSocketServer) void {
        self.stop();
        for (self.clients.items) |*client| {
            client.deinit();
        }
        self.clients.deinit(self.allocator);
    }

    /// Start WebSocket server
    pub fn start(self: *WebSocketServer) !void {
        const address = try std.net.Address.parseIp("127.0.0.1", self.port);
        var server = try address.listen(.{
            .reuse_address = true,
            .reuse_port = true,
        });

        self.server = server;
        self.running.store(true, .seq_cst);

        std.debug.print("WebSocket server listening on ws://127.0.0.1:{d}\n", .{self.port});

        while (self.running.load(.seq_cst)) {
            var connection = server.accept() catch |err| switch (err) {
                error.ConnectionResetByPeer => continue,
                error.ConnectionAborted => continue,
                else => return err,
            };

            // Handle WebSocket upgrade
            self.handleConnection(connection.stream) catch |err| {
                std.debug.print("WebSocket connection error: {}\n", .{err});
                connection.stream.close();
            };
        }
    }

    /// Stop WebSocket server
    pub fn stop(self: *WebSocketServer) void {
        self.running.store(false, .seq_cst);
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
    }

    /// Handle a new connection
    fn handleConnection(self: *WebSocketServer, stream: std.net.Stream) !void {
        var buffer: [4096]u8 = undefined;
        const bytes_read = try stream.read(&buffer);

        if (bytes_read == 0) return;

        // Check for WebSocket upgrade request
        if (std.mem.indexOf(u8, buffer[0..bytes_read], "Upgrade: websocket")) |_| {
            try self.performHandshake(stream, buffer[0..bytes_read]);

            var client = WebSocketClient{
                .stream = stream,
                .subscriptions = std.ArrayList(Subscription).init(self.allocator),
                .allocator = self.allocator,
            };

            // Read first frame(s) to handle subscribe (e.g. {"command":"subscribe","streams":["ledger"]})
            var frame_buf: [4096]u8 = undefined;
            if (readFrame(stream, &frame_buf)) |payload| {
                parseSubscribePayload(payload, &client);
            } else |_| {}

            try self.clients.append(self.allocator, client);
        }
    }

    /// Perform WebSocket handshake (RFC 6455)
    fn performHandshake(self: *WebSocketServer, stream: std.net.Stream, request: []const u8) !void {
        _ = self;
        const key_start = std.mem.indexOf(u8, request, "Sec-WebSocket-Key: ") orelse return error.MissingKey;
        const key_line = request[key_start + 19 ..];
        const key_end = std.mem.indexOf(u8, key_line, "\r\n") orelse return error.InvalidKey;
        const key = std.mem.trim(u8, key_line[0..key_end], &std.ascii.whitespace);

        // RFC 6455: Accept = Base64(SHA1(key + magic))
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var combined: [key.len + magic.len]u8 = undefined;
        @memcpy(combined[0..key.len], key);
        @memcpy(combined[key.len..], magic);

        var digest: [20]u8 = undefined;
        std.crypto.hash.sha1.Sha1.hash(&combined, &digest, .{});
        var b64_buf: [28]u8 = undefined;
        const accept_b64 = std.base64.standard.Encoder.encode(&b64_buf, &digest);

        var response_buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf,
            \\HTTP/1.1 101 Switching Protocols
            \\Upgrade: websocket
            \\Connection: Upgrade
            \\Sec-WebSocket-Accept: {s}
            \\
            \\
        , .{accept_b64}) catch return error.ResponseTooLong;

        _ = try stream.write(response);
    }

    /// Broadcast ledger close to all subscribed clients
    pub fn broadcastLedgerClose(self: *WebSocketServer, ledger_seq: types.LedgerSequence) !void {
        const message = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "type": "ledgerClosed",
            \\  "ledger_index": {d},
            \\  "ledger_hash": "placeholder"
            \\}}
        , .{ledger_seq});
        defer self.allocator.free(message);

        for (self.clients.items) |*client| {
            for (client.subscriptions.items) |sub| {
                if (sub == .ledger) {
                    client.send(message) catch |err| {
                        std.debug.print("Failed to send to client: {}\n", .{err});
                    };
                }
            }
        }
    }
};

/// WebSocket client connection
pub const WebSocketClient = struct {
    stream: std.net.Stream,
    subscriptions: std.ArrayList(Subscription),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WebSocketClient) void {
        self.stream.close();
        self.subscriptions.deinit(self.allocator);
    }

    /// Send message to client (RFC 6455 text frame, server->client no masking)
    pub fn send(self: *WebSocketClient, message: []const u8) !void {
        var header: [14]u8 = undefined; // max header for extended length
        header[0] = 0x81; // FIN + text frame
        var header_len: usize = 2;
        if (message.len < 126) {
            header[1] = @intCast(message.len);
        } else if (message.len < 65536) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(message.len), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], message.len, .big);
            header_len = 10;
        }
        _ = try self.stream.write(header[0..header_len]);
        _ = try self.stream.write(message);
    }

    /// Subscribe to a stream
    pub fn subscribe(self: *WebSocketClient, sub: Subscription) !void {
        try self.subscriptions.append(self.allocator, sub);
    }
};

/// Read one RFC 6455 WebSocket frame
fn readFrame(stream: std.net.Stream, out: []u8) ![]u8 {
    var header: [2]u8 = undefined;
    _ = try stream.readAll(&header);
    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;
    var payload_len: usize = header[1] & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        _ = try stream.readAll(&ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        _ = try stream.readAll(&ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }
    if (payload_len > out.len) return error.PayloadTooLarge;
    var mask_key: [4]u8 = undefined;
    if (masked) _ = try stream.readAll(&mask_key);
    const n = try stream.readAll(out[0..payload_len]);
    if (n != payload_len) return error.TruncatedFrame;
    if (masked) {
        for (out[0..payload_len], 0..) |*b, i| b.* ^= mask_key[i % 4];
    }
    if (opcode == 0x8) return error.ConnectionClosed; // close frame
    return out[0..payload_len];
}

fn parseSubscribePayload(payload: []const u8, client: *WebSocketClient) void {
    if (std.mem.indexOf(u8, payload, "\"ledger\"") != null) {
        client.subscribe(.ledger) catch {};
    }
    if (std.mem.indexOf(u8, payload, "\"transactions\"") != null) {
        client.subscribe(.transactions) catch {};
    }
    if (std.mem.indexOf(u8, payload, "\"validations\"") != null) {
        client.subscribe(.validations) catch {};
    }
}

/// Subscription types
pub const Subscription = enum {
    ledger,
    transactions,
    validations,
    manifests,
    peer_status,
    consensus,
    server,
};

test "websocket initialization" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var ws = try WebSocketServer.init(allocator, 6006, &lm);
    defer ws.deinit();

    try std.testing.expectEqual(@as(u16, 6006), ws.port);
    try std.testing.expectEqual(@as(usize, 0), ws.clients.items.len);
}
