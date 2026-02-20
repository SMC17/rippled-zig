const std = @import("std");
const base58 = @import("base58.zig");
const ledger = @import("ledger.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");
const rpc_methods = @import("rpc_methods.zig");

/// JSON-RPC and HTTP API server
pub const RpcServer = struct {
    const max_json_rpc_body_bytes: usize = 32 * 1024;
    const max_method_name_len: usize = 64;

    allocator: std.mem.Allocator,
    port: u16,
    ledger_manager: *ledger.LedgerManager,
    account_state: *ledger.AccountState,
    tx_processor: *transaction.TransactionProcessor,
    methods: rpc_methods.RpcMethods,
    server: ?std.net.Server,
    running: std.atomic.Value(bool),
    start_time: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        ledger_manager: *ledger.LedgerManager,
        account_state: *ledger.AccountState,
        tx_processor: *transaction.TransactionProcessor,
    ) RpcServer {
        return RpcServer{
            .allocator = allocator,
            .port = port,
            .ledger_manager = ledger_manager,
            .account_state = account_state,
            .tx_processor = tx_processor,
            .methods = rpc_methods.RpcMethods.init(allocator, ledger_manager, account_state, tx_processor),
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
            if (!(std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/jsonrpc"))) {
                return self.send404Response();
            }
            const body = extractHttpBody(request) catch |err| switch (err) {
                error.NoBody => return self.buildRpcErrorResponse("Missing request body"),
                error.IncompleteBody => return self.buildRpcErrorResponse("Incomplete request body"),
                error.PayloadTooLarge => return self.buildRpcHttpErrorResponse(413, "Payload Too Large", "Request body too large"),
                else => return self.buildRpcErrorResponse("Invalid request body"),
            };

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

    fn wrapJsonHttpResponse(self: *RpcServer, json_body: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\Connection: close
            \\
            \\{s}
        , .{json_body});
    }

    fn buildRpcErrorResponse(self: *RpcServer, message: []const u8) ![]u8 {
        return self.buildRpcHttpErrorResponse(400, "Bad Request", message);
    }

    fn buildRpcHttpErrorResponse(self: *RpcServer, code: u16, status: []const u8, message: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 {d} {s}
            \\Content-Type: application/json
            \\Connection: close
            \\
            \\{{"error": "{s}"}}
        , .{ code, status, message });
    }

    fn parseContentLength(headers: []const u8) !?usize {
        var lines = std.mem.splitScalar(u8, headers, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \r");
            if (line.len == 0) continue;

            const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon_idx], " ");
            if (!std.ascii.eqlIgnoreCase(key, "Content-Length")) continue;

            const value = std.mem.trim(u8, line[colon_idx + 1 ..], " ");
            return try std.fmt.parseInt(usize, value, 10);
        }

        return null;
    }

    fn extractHttpBody(request: []const u8) ![]const u8 {
        var body_start: ?usize = null;
        var body_offset: usize = 0;
        if (std.mem.indexOf(u8, request, "\r\n\r\n")) |idx| {
            body_start = idx;
            body_offset = 4;
        } else if (std.mem.indexOf(u8, request, "\n\n")) |idx| {
            body_start = idx;
            body_offset = 2;
        }

        const header_end = body_start orelse return error.NoBody;
        const headers = request[0..header_end];
        const body = request[header_end + body_offset ..];

        if (try parseContentLength(headers)) |content_len| {
            if (content_len > max_json_rpc_body_bytes) return error.PayloadTooLarge;
            if (body.len < content_len) return error.IncompleteBody;
            return body[0..content_len];
        }

        if (body.len > max_json_rpc_body_bytes) return error.PayloadTooLarge;
        return body;
    }

    fn isValidMethodName(method: []const u8) bool {
        if (method.len == 0 or method.len > max_method_name_len) return false;
        for (method) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') continue;
            return false;
        }
        return true;
    }

    fn parseJsonRpcMethod(body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidRequest,
        };
        const method_value = root.get("method") orelse return error.InvalidRequest;
        return switch (method_value) {
            .string => |s| blk: {
                if (!isValidMethodName(s)) return error.InvalidRequest;
                break :blk try allocator.dupe(u8, s);
            },
            else => error.InvalidRequest,
        };
    }

    fn parseAgentConfigSetParams(body: []const u8, allocator: std.mem.Allocator) !struct { key: []u8, value: []u8 } {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidRequest,
        };
        const params_value = root.get("params") orelse return error.InvalidRequest;
        const first = switch (params_value) {
            .array => |arr| blk: {
                if (arr.items.len == 0) return error.InvalidRequest;
                break :blk switch (arr.items[0]) {
                    .object => |obj| obj,
                    else => return error.InvalidRequest,
                };
            },
            .object => |obj| obj,
            else => return error.InvalidRequest,
        };
        const key = switch (first.get("key") orelse return error.InvalidRequest) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidRequest,
        };
        errdefer allocator.free(key);
        const raw_value = first.get("value") orelse return error.InvalidRequest;
        const value = switch (raw_value) {
            .string => |s| try allocator.dupe(u8, s),
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            else => return error.InvalidRequest,
        };
        return .{ .key = key, .value = value };
    }

    fn requestHasParams(body: []const u8, allocator: std.mem.Allocator) !bool {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidRequest,
        };
        return root.get("params") != null;
    }

    fn parseSingleParamsObject(root: std.json.ObjectMap) !std.json.ObjectMap {
        const params_value = root.get("params") orelse return error.InvalidRequest;
        return switch (params_value) {
            .object => |obj| obj,
            .array => |arr| blk: {
                if (arr.items.len == 0) return error.InvalidRequest;
                break :blk switch (arr.items[0]) {
                    .object => |obj| obj,
                    else => return error.InvalidRequest,
                };
            },
            else => error.InvalidRequest,
        };
    }

    fn parseAccountInfoParams(body: []const u8, allocator: std.mem.Allocator) !types.AccountID {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidRequest,
        };
        const params = try parseSingleParamsObject(root);
        const account = switch (params.get("account") orelse return error.InvalidRequest) {
            .string => |s| s,
            else => return error.InvalidRequest,
        };
        return base58.Base58.decodeAccountID(allocator, account) catch error.InvalidRequest;
    }

    fn parseSubmitParams(body: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidRequest,
        };
        const params = try parseSingleParamsObject(root);
        const tx_blob = switch (params.get("tx_blob") orelse return error.InvalidRequest) {
            .string => |s| s,
            else => return error.InvalidRequest,
        };
        if (tx_blob.len == 0) return error.InvalidRequest;
        if (tx_blob.len % 2 != 0) return error.InvalidRequest;
        // Keep submit payload bounded for request safety and deterministic behavior.
        if (tx_blob.len > max_json_rpc_body_bytes * 2) return error.InvalidRequest;

        for (tx_blob) |c| {
            const is_hex = (c >= '0' and c <= '9') or
                (c >= 'a' and c <= 'f') or
                (c >= 'A' and c <= 'F');
            if (!is_hex) return error.InvalidRequest;
        }
        return try allocator.dupe(u8, tx_blob);
    }

    /// Handle JSON-RPC request
    fn handleJsonRpc(self: *RpcServer, body: []const u8) ![]u8 {
        const uptime_i64 = std.time.timestamp() - self.start_time;
        const uptime = if (uptime_i64 < 0) @as(u64, 0) else @as(u64, @intCast(uptime_i64));

        const method = parseJsonRpcMethod(body, self.allocator) catch return self.buildRpcErrorResponse("Invalid JSON-RPC request");
        defer self.allocator.free(method);
        if (!self.methods.isMethodAllowedForProfile(method)) {
            return self.buildRpcErrorResponse("Method blocked by profile policy");
        }

        if (std.mem.eql(u8, method, "server_info")) {
            const payload = try self.methods.serverInfo(uptime);
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "account_info")) {
            const account_id = parseAccountInfoParams(body, self.allocator) catch return self.buildRpcErrorResponse("Invalid account_info params");
            const payload = try self.methods.accountInfo(account_id);
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "ledger")) {
            const payload = try self.methods.ledgerInfo(null);
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "ledger_current")) {
            const has_params = requestHasParams(body, self.allocator) catch return self.buildRpcErrorResponse("Invalid JSON-RPC request");
            if (has_params) return self.buildRpcErrorResponse("ledger_current does not accept params");
            const payload = try self.methods.ledgerCurrent();
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "fee")) {
            const payload = try self.methods.fee();
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "submit")) {
            const tx_blob = parseSubmitParams(body, self.allocator) catch return self.buildRpcErrorResponse("Invalid submit params");
            defer self.allocator.free(tx_blob);
            const payload = self.methods.submit(tx_blob) catch |err| switch (err) {
                error.InvalidTxBlob => return self.buildRpcErrorResponse("Invalid submit tx_blob"),
                error.UnsupportedTransactionType => return self.buildRpcErrorResponse("Unsupported submit transaction type"),
                error.AccountNotFound => return self.buildRpcErrorResponse("Submit account not found"),
                error.SubmitFeeTooLow => return self.buildRpcErrorResponse("Submit fee below minimum"),
                error.SubmitSequenceMismatch => return self.buildRpcErrorResponse("Submit sequence mismatch"),
                error.SubmitInsufficientFeeBalance => return self.buildRpcErrorResponse("Submit fee balance insufficient"),
                error.DestinationAccountNotFound => return self.buildRpcErrorResponse("Submit destination account not found"),
                error.InvalidPaymentAmount => return self.buildRpcErrorResponse("Invalid submit payment amount"),
                error.InsufficientPaymentBalance => return self.buildRpcErrorResponse("Insufficient submit payment balance"),
                else => return err,
            };
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "ping")) {
            const has_params = requestHasParams(body, self.allocator) catch return self.buildRpcErrorResponse("Invalid JSON-RPC request");
            if (has_params) return self.buildRpcErrorResponse("ping does not accept params");
            const payload = try self.methods.ping();
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "agent_status")) {
            const payload = try self.methods.agentStatus(uptime);
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "agent_config_get")) {
            const payload = try self.methods.agentConfigGet();
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }
        if (std.mem.eql(u8, method, "agent_config_set")) {
            const params = parseAgentConfigSetParams(body, self.allocator) catch return self.buildRpcErrorResponse("Invalid agent_config_set params");
            defer self.allocator.free(params.key);
            defer self.allocator.free(params.value);
            const payload = self.methods.agentConfigSet(params.key, params.value) catch |err| switch (err) {
                error.UnsupportedConfigKey => return self.buildRpcErrorResponse("Unsupported config key"),
                error.InvalidConfigValue => return self.buildRpcErrorResponse("Invalid config value"),
                error.ConfigValueOutOfRange => return self.buildRpcErrorResponse("Config value out of range"),
                error.UnsafeProfileTransition => return self.buildRpcErrorResponse("Unsafe profile transition"),
                error.PolicyViolation => return self.buildRpcErrorResponse("Policy violation for current profile"),
                else => return err,
            };
            defer self.allocator.free(payload);
            return self.wrapJsonHttpResponse(payload);
        }

        return self.buildRpcErrorResponse("Unknown method");
    }

    pub fn handleJsonRpcRequest(self: *RpcServer, body: []const u8) ![]u8 {
        return self.handleJsonRpc(body);
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
            .{ "ledger_current", .ledger_current },
            .{ "account_info", .account_info },
            .{ "submit", .submit },
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
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 5005), server.port);
    try std.testing.expect(!server.running.load(.seq_cst));
}

test "rpc method from string" {
    try std.testing.expectEqual(RpcMethod.server_info, RpcMethod.fromString("server_info").?);
    try std.testing.expectEqual(RpcMethod.ledger, RpcMethod.fromString("ledger").?);
    try std.testing.expectEqual(RpcMethod.ledger_current, RpcMethod.fromString("ledger_current").?);
    try std.testing.expectEqual(RpcMethod.submit, RpcMethod.fromString("submit").?);
    try std.testing.expectEqual(RpcMethod.agent_status, RpcMethod.fromString("agent_status").?);
    try std.testing.expectEqual(@as(?RpcMethod, null), RpcMethod.fromString("invalid"));
}

test "json-rpc agent methods are wired" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    const status_response = try server.handleJsonRpc("{\"method\":\"agent_status\"}");
    defer allocator.free(status_response);
    try std.testing.expect(std.mem.indexOf(u8, status_response, "\"agent_control\"") != null);

    const set_response = try server.handleJsonRpc("{\"method\":\"agent_config_set\",\"params\":[{\"key\":\"max_peers\",\"value\":\"31\"}]}");
    defer allocator.free(set_response);
    try std.testing.expect(std.mem.indexOf(u8, set_response, "\"status\": \"success\"") != null);

    const get_response = try server.handleJsonRpc("{\"method\":\"agent_config_get\"}");
    defer allocator.free(get_response);
    try std.testing.expect(std.mem.indexOf(u8, get_response, "\"max_peers\": 31") != null);
}

test "json-rpc agent_config_set accepts numeric and boolean params" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    const set_num = try server.handleJsonRpc("{\"method\":\"agent_config_set\",\"params\":{\"key\":\"max_peers\",\"value\":35}}");
    defer allocator.free(set_num);
    try std.testing.expect(std.mem.indexOf(u8, set_num, "\"status\": \"success\"") != null);

    const set_bool = try server.handleJsonRpc("{\"method\":\"agent_config_set\",\"params\":{\"key\":\"allow_unl_updates\",\"value\":true}}");
    defer allocator.free(set_bool);
    try std.testing.expect(std.mem.indexOf(u8, set_bool, "\"status\": \"success\"") != null);

    const get_response = try server.handleJsonRpc("{\"method\":\"agent_config_get\"}");
    defer allocator.free(get_response);
    try std.testing.expect(std.mem.indexOf(u8, get_response, "\"max_peers\": 35") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_response, "\"allow_unl_updates\": true") != null);
}

test "http post rejects incomplete body and invalid method names" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    const short_request =
        "POST / HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 30\r\n\r\n" ++
        "{\"method\":\"ping\"}";
    const short_resp = try server.handleHttpRequest(short_request);
    defer allocator.free(short_resp);
    try std.testing.expect(std.mem.indexOf(u8, short_resp, "400 Bad Request") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_resp, "Incomplete request body") != null);

    const invalid_method_body = "{\"method\":\"agent-status\"}";
    const invalid_method_request = try std.fmt.allocPrint(
        allocator,
        "POST /jsonrpc HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ invalid_method_body.len, invalid_method_body },
    );
    defer allocator.free(invalid_method_request);

    const invalid_method_resp = try server.handleHttpRequest(invalid_method_request);
    defer allocator.free(invalid_method_resp);
    try std.testing.expect(std.mem.indexOf(u8, invalid_method_resp, "Invalid JSON-RPC request") != null);
}

test "json-rpc live method coverage for account_info submit ping ledger_current" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const account = [_]u8{1} ** 20;
    const destination = [_]u8{2} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 500 * 1_000_000,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });
    try state.putAccount(.{
        .account = destination,
        .balance = 10 * 1_000_000,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });
    const account_addr = try base58.Base58.encodeAccountID(allocator, account);
    defer allocator.free(account_addr);

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    const account_req = try std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"account_info\",\"params\":{{\"account\":\"{s}\"}}}}",
        .{account_addr},
    );
    defer allocator.free(account_req);
    const account_resp = try server.handleJsonRpc(account_req);
    defer allocator.free(account_resp);
    try std.testing.expect(std.mem.indexOf(u8, account_resp, "\"status\": \"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, account_resp, "\"account_data\"") != null);

    // Minimal tx blob format for payment:
    // tx_type=payment(0), account=0x01*20, fee=10, sequence=1,
    // destination=0x02*20, amount=1000000 (1 XRP)
    const tx_blob =
        "0000" ++
        "0101010101010101010101010101010101010101" ++
        "000000000000000a" ++
        "00000001" ++
        "0202020202020202020202020202020202020202" ++
        "00000000000f4240";
    const submit_req = try std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"submit\",\"params\":{{\"tx_blob\":\"{s}\"}}}}",
        .{tx_blob},
    );
    defer allocator.free(submit_req);
    const submit_resp = try server.handleJsonRpc(submit_req);
    defer allocator.free(submit_resp);
    try std.testing.expect(std.mem.indexOf(u8, submit_resp, "\"engine_result\": \"tesSUCCESS\"") != null);

    const ping_resp = try server.handleJsonRpc("{\"method\":\"ping\"}");
    defer allocator.free(ping_resp);
    try std.testing.expect(std.mem.indexOf(u8, ping_resp, "\"result\": {}") != null);

    const ledger_current_resp = try server.handleJsonRpc("{\"method\":\"ledger_current\"}");
    defer allocator.free(ledger_current_resp);
    try std.testing.expect(std.mem.indexOf(u8, ledger_current_resp, "\"ledger_current_index\"") != null);
}

test "json-rpc profile policy blocks unsafe production transitions" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    const set_strict_false = try server.handleJsonRpc("{\"method\":\"agent_config_set\",\"params\":{\"key\":\"strict_crypto_required\",\"value\":false}}");
    defer allocator.free(set_strict_false);
    try std.testing.expect(std.mem.indexOf(u8, set_strict_false, "\"status\": \"success\"") != null);

    const set_prod = try server.handleJsonRpc("{\"method\":\"agent_config_set\",\"params\":{\"key\":\"profile\",\"value\":\"production\"}}");
    defer allocator.free(set_prod);
    try std.testing.expect(std.mem.indexOf(u8, set_prod, "Unsafe profile transition") != null);
}

test "production profile enforces rpc method allowlist" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const account = [_]u8{1} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 1_000 * 1_000_000,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });
    const account_addr = try base58.Base58.encodeAccountID(allocator, account);
    defer allocator.free(account_addr);

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    const set_prod = try server.handleJsonRpc("{\"method\":\"agent_config_set\",\"params\":{\"key\":\"profile\",\"value\":\"production\"}}");
    defer allocator.free(set_prod);
    try std.testing.expect(std.mem.indexOf(u8, set_prod, "\"status\": \"success\"") != null);

    // Allowed in production.
    const account_req = try std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"account_info\",\"params\":{{\"account\":\"{s}\"}}}}",
        .{account_addr},
    );
    defer allocator.free(account_req);
    const allowed_resp = try server.handleJsonRpc(account_req);
    defer allocator.free(allowed_resp);
    try std.testing.expect(std.mem.indexOf(u8, allowed_resp, "\"status\": \"success\"") != null);

    // Denied in production.
    const blocked_submit = try server.handleJsonRpc("{\"method\":\"submit\",\"params\":{\"tx_blob\":\"DEADBEEF\"}}");
    defer allocator.free(blocked_submit);
    try std.testing.expect(std.mem.indexOf(u8, blocked_submit, "Method blocked by profile policy") != null);

    const blocked_config_set = try server.handleJsonRpc("{\"method\":\"agent_config_set\",\"params\":{\"key\":\"max_peers\",\"value\":30}}");
    defer allocator.free(blocked_config_set);
    try std.testing.expect(std.mem.indexOf(u8, blocked_config_set, "Method blocked by profile policy") != null);
}

test "submit rejects non-hex tx_blob" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    const resp = try server.handleJsonRpc("{\"method\":\"submit\",\"params\":{\"tx_blob\":\"DEADZEEF\"}}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Invalid submit params") != null);
}

test "submit rejects malformed tx_blob structure" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    const resp = try server.handleJsonRpc("{\"method\":\"submit\",\"params\":{\"tx_blob\":\"DEADBEEF\"}}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Invalid submit tx_blob") != null);
}

test "submit rejects unsupported transaction type deterministically" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    // tx_type=0xFFFF, account=0x01*20, fee=10, sequence=5
    const req =
        "{\"method\":\"submit\",\"params\":{\"tx_blob\":\"FFFF0101010101010101010101010101010101010101000000000000000A00000005\"}}";
    const resp = try server.handleJsonRpc(req);
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Unsupported submit transaction type") != null);
}

test "submit payment errors are deterministic" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const sender = [_]u8{1} ** 20;
    const existing_destination = [_]u8{2} ** 20;
    try state.putAccount(.{
        .account = sender,
        .balance = 2 * 1_000_000,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 8,
    });
    try state.putAccount(.{
        .account = existing_destination,
        .balance = 1 * 1_000_000,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    // destination account 0x03*20 does not exist
    const missing_dest_req =
        "{\"method\":\"submit\",\"params\":{\"tx_blob\":\"00000101010101010101010101010101010101010101000000000000000A00000008030303030303030303030303030303030303030300000000000003E8\"}}";
    const missing_dest_resp = try server.handleJsonRpc(missing_dest_req);
    defer allocator.free(missing_dest_resp);
    try std.testing.expect(std.mem.indexOf(u8, missing_dest_resp, "Submit destination account not found") != null);

    // account has ~2 XRP and cannot pay 200 XRP.
    const insufficient_req =
        "{\"method\":\"submit\",\"params\":{\"tx_blob\":\"00000101010101010101010101010101010101010101000000000000000A000000080202020202020202020202020202020202020202000000000BEBC200\"}}";
    const insufficient_resp = try server.handleJsonRpc(insufficient_req);
    defer allocator.free(insufficient_resp);
    try std.testing.expect(std.mem.indexOf(u8, insufficient_resp, "Insufficient submit payment balance") != null);
}

test "submit sequence and fee boundary errors are deterministic and mutation-safe" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();
    var state = ledger.AccountState.init(allocator);
    defer state.deinit();
    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const sender = [_]u8{1} ** 20;
    const destination = [_]u8{2} ** 20;
    try state.putAccount(.{
        .account = sender,
        .balance = 50 * 1_000_000,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 7,
    });
    try state.putAccount(.{
        .account = destination,
        .balance = 4 * 1_000_000,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    const before_sender = state.getAccount(sender).?;
    const before_destination = state.getAccount(destination).?;

    var server = RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer server.deinit();

    // Sequence mismatch (account seq is 7, request uses 8).
    const seq_req =
        "{\"method\":\"submit\",\"params\":{\"tx_blob\":\"00000101010101010101010101010101010101010101000000000000000A00000008020202020202020202020202020202020202020200000000000F4240\"}}";
    const seq_resp = try server.handleJsonRpc(seq_req);
    defer allocator.free(seq_resp);
    try std.testing.expect(std.mem.indexOf(u8, seq_resp, "Submit sequence mismatch") != null);

    var after_sender = state.getAccount(sender).?;
    var after_destination = state.getAccount(destination).?;
    try std.testing.expectEqual(before_sender.sequence, after_sender.sequence);
    try std.testing.expectEqual(before_sender.balance, after_sender.balance);
    try std.testing.expectEqual(before_destination.balance, after_destination.balance);
    try std.testing.expectEqual(@as(usize, 0), processor.getPendingTransactions().len);

    // Fee below minimum (9 drops).
    const fee_req =
        "{\"method\":\"submit\",\"params\":{\"tx_blob\":\"00000101010101010101010101010101010101010101000000000000000900000007020202020202020202020202020202020202020200000000000F4240\"}}";
    const fee_resp = try server.handleJsonRpc(fee_req);
    defer allocator.free(fee_resp);
    try std.testing.expect(std.mem.indexOf(u8, fee_resp, "Submit fee below minimum") != null);

    after_sender = state.getAccount(sender).?;
    after_destination = state.getAccount(destination).?;
    try std.testing.expectEqual(before_sender.sequence, after_sender.sequence);
    try std.testing.expectEqual(before_sender.balance, after_sender.balance);
    try std.testing.expectEqual(before_destination.balance, after_destination.balance);
    try std.testing.expectEqual(@as(usize, 0), processor.getPendingTransactions().len);
}
