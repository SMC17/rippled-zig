const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");

/// JSON-RPC and HTTP API server
pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    ledger_manager: *ledger.LedgerManager,
    server: ?std.net.Server,
    running: std.atomic.Value(bool),
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator, port: u16, ledger_manager: *ledger.LedgerManager) RpcServer {
        return RpcServer{
            .allocator = allocator,
            .port = port,
            .ledger_manager = ledger_manager,
            .server = null,
            .running = std.atomic.Value(bool).init(false),
            .start_time = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *RpcServer) void {
        self.stop();
    }

    /// Start the RPC server
    pub fn start(self: *RpcServer) !void {
        const address = try std.net.Address.parseIp("127.0.0.1", self.port);

        var server = try address.listen(.{
            .reuse_address = true,
            .reuse_port = true,
        });

        self.server = server;
        self.running.store(true, .seq_cst);

        std.debug.print("RPC Server listening on http://127.0.0.1:{d}\n", .{self.port});

        // Accept HTTP connections
        while (self.running.load(.seq_cst)) {
            var connection = server.accept() catch |err| switch (err) {
                error.ConnectionResetByPeer => continue,
                error.ConnectionAborted => continue,
                else => return err,
            };
            defer connection.stream.close();

            // Handle the HTTP request
            self.handleConnection(&connection.stream) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
            };
        }
    }

    /// Stop the RPC server
    pub fn stop(self: *RpcServer) void {
        self.running.store(false, .seq_cst);
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
    }

    /// Handle HTTP connection
    fn handleConnection(self: *RpcServer, stream: *std.net.Stream) !void {
        var buffer: [4096]u8 = undefined;
        const bytes_read = try stream.read(&buffer);

        if (bytes_read == 0) return;

        const request = buffer[0..bytes_read];

        // Parse HTTP request (simplified)
        const response = self.handleHttpRequest(request) catch |err| {
            std.debug.print("Error handling request: {}\n", .{err});
            return self.sendErrorResponse(stream, 500, "Internal Server Error");
        };
        defer self.allocator.free(response);

        // Send HTTP response
        _ = try stream.write(response);
    }

    /// Handle HTTP request and return response
    fn handleHttpRequest(self: *RpcServer, request: []const u8) ![]u8 {
        // Parse request line
        var lines = std.mem.splitScalar(u8, request, '\n');
        const first_line = lines.next() orelse return error.InvalidRequest;

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;

        // Route based on path
        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.startsWith(u8, path, "/server_info")) {
                return self.handleServerInfo();
            } else if (std.mem.startsWith(u8, path, "/ledger")) {
                return self.handleLedgerInfo();
            } else if (std.mem.startsWith(u8, path, "/health")) {
                return self.handleHealth();
            } else {
                return self.send404Response();
            }
        } else if (std.mem.eql(u8, method, "POST")) {
            // Find the JSON body
            const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse
                std.mem.indexOf(u8, request, "\n\n") orelse
                return error.NoBody;
            const body = request[body_start + 4 ..];

            return self.handleJsonRpc(body);
        }

        return self.send404Response();
    }

    /// Handle server_info RPC method
    fn handleServerInfo(self: *RpcServer) ![]u8 {
        const current_ledger = self.ledger_manager.getCurrentLedger();
        const uptime = std.time.timestamp() - self.start_time;

        const response_json = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\Connection: close
            \\
            \\{{
            \\  "result": {{
            \\    "status": "success",
            \\    "info": {{
            \\      "build_version": "rippled-zig-0.1.0-alpha",
            \\      "complete_ledgers": "1-{d}",
            \\      "ledger_seq": {d},
            \\      "peers": 0,
            \\      "state": "full",
            \\      "uptime": {d},
            \\      "validated_ledger": {{
            \\        "seq": {d},
            \\        "close_time": {d}
            \\      }}
            \\    }}
            \\  }}
            \\}}
        , .{ current_ledger.sequence, current_ledger.sequence, uptime, current_ledger.sequence, current_ledger.close_time });

        return response_json;
    }

    /// Handle ledger info RPC method
    fn handleLedgerInfo(self: *RpcServer) ![]u8 {
        const current_ledger = self.ledger_manager.getCurrentLedger();

        const response_json = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\Connection: close
            \\
            \\{{
            \\  "result": {{
            \\    "status": "success",
            \\    "ledger": {{
            \\      "ledger_index": {d},
            \\      "closed": true,
            \\      "close_time": {d},
            \\      "total_coins": "{d}"
            \\    }}
            \\  }}
            \\}}
        , .{ current_ledger.sequence, current_ledger.close_time, current_ledger.total_coins });

        return response_json;
    }

    /// Handle health check
    fn handleHealth(self: *RpcServer) ![]u8 {
        return try self.allocator.dupe(u8,
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\Connection: close
            \\
            \\{"status": "healthy"}
        );
    }

    /// Handle JSON-RPC request
    fn handleJsonRpc(self: *RpcServer, body: []const u8) ![]u8 {
        // Parse JSON (simplified - just detect method)
        if (std.mem.indexOf(u8, body, "\"server_info\"")) |_| {
            return self.handleServerInfo();
        } else if (std.mem.indexOf(u8, body, "\"ledger\"")) |_| {
            return self.handleLedgerInfo();
        }

        return self.sendErrorResponse(null, 400, "Unknown method");
    }

    /// Send 404 response
    fn send404Response(self: *RpcServer) ![]u8 {
        return try self.allocator.dupe(u8,
            \\HTTP/1.1 404 Not Found
            \\Content-Type: application/json
            \\Connection: close
            \\
            \\{"error": "Not Found"}
        );
    }

    /// Send error response
    fn sendErrorResponse(self: *RpcServer, stream: ?*std.net.Stream, code: u16, message: []const u8) !void {
        const response = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 {d} {s}
            \\Content-Type: application/json
            \\Connection: close
            \\
            \\{{"error": "{s}"}}
        , .{ code, message, message });
        defer self.allocator.free(response);

        if (stream) |s| {
            _ = try s.write(response);
        }
    }
};

/// RPC method types
pub const RpcMethod = enum {
    // Account methods
    account_info,
    account_currencies,
    account_lines,
    account_objects,
    account_tx,

    // Ledger methods
    ledger,
    ledger_closed,
    ledger_current,
    ledger_data,
    ledger_entry,

    // Transaction methods
    submit,
    submit_multisigned,
    tx,
    tx_history,

    // Server methods
    server_info,
    server_state,
    fee,

    // Utility methods
    ping,
    random,

    // Agent control methods
    agent_status,
    agent_config_get,
    agent_config_set,

    pub fn fromString(str: []const u8) ?RpcMethod {
        const map = std.StaticStringMap(RpcMethod).initComptime(.{
            .{ "server_info", .server_info },
            .{ "ledger", .ledger },
            .{ "account_info", .account_info },
            .{ "ping", .ping },
            .{ "agent_status", .agent_status },
            .{ "agent_config_get", .agent_config_get },
            .{ "agent_config_set", .agent_config_set },
        });
        return map.get(str);
    }
};

test "rpc server initialization" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var server = RpcServer.init(allocator, 5005, &lm);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 5005), server.port);
    try std.testing.expect(!server.running.load(.seq_cst));
}

test "rpc method from string" {
    try std.testing.expectEqual(RpcMethod.server_info, RpcMethod.fromString("server_info").?);
    try std.testing.expectEqual(RpcMethod.ledger, RpcMethod.fromString("ledger").?);
    try std.testing.expectEqual(RpcMethod.agent_status, RpcMethod.fromString("agent_status").?);
    try std.testing.expectEqual(@as(?RpcMethod, null), RpcMethod.fromString("invalid"));
}
