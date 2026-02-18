const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");
const transaction = @import("transaction.zig");
const base58 = @import("base58.zig");
const rpc_format = @import("rpc_format.zig");

/// Complete RPC method implementations
pub const RpcMethods = struct {
    pub const AgentControlConfig = struct {
        max_peers: u32 = 21,
        fee_multiplier: u32 = 1,
        strict_crypto_required: bool = true,
        allow_unl_updates: bool = false,
    };

    allocator: std.mem.Allocator,
    ledger_manager: *ledger.LedgerManager,
    account_state: *ledger.AccountState,
    tx_processor: *transaction.TransactionProcessor,
    agent_config: AgentControlConfig,

    pub fn init(
        allocator: std.mem.Allocator,
        ledger_manager: *ledger.LedgerManager,
        account_state: *ledger.AccountState,
        tx_processor: *transaction.TransactionProcessor,
    ) RpcMethods {
        return RpcMethods{
            .allocator = allocator,
            .ledger_manager = ledger_manager,
            .account_state = account_state,
            .tx_processor = tx_processor,
            .agent_config = .{},
        };
    }

    /// account_info - Get information about an account
    /// WEEK 3 DAY 15: Fixed to match rippled format (Base58 address)
    pub fn accountInfo(self: *RpcMethods, account_id: types.AccountID) ![]u8 {
        const account = self.account_state.getAccount(account_id) orelse {
            return try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "error": "actNotFound",
                \\  "error_code": 15,
                \\  "error_message": "Account not found.",
                \\  "status": "error",
                \\  "validated": true
                \\}}
            , .{});
        };

        const current_ledger = self.ledger_manager.getCurrentLedger();

        // Convert account ID to Base58 address (FIXED Day 15)
        const address = try base58.Base58.encodeAccountID(self.allocator, account.account);
        defer self.allocator.free(address);

        // Balance must be string in drops (XRPL format)
        const balance_str = try std.fmt.allocPrint(self.allocator, "{d}", .{account.balance});
        defer self.allocator.free(balance_str);

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "account_data": {{
            \\      "Account": "{s}",
            \\      "Balance": "{s}",
            \\      "Flags": {d},
            \\      "OwnerCount": {d},
            \\      "Sequence": {d}
            \\    }},
            \\    "ledger_current_index": {d},
            \\    "status": "success",
            \\    "validated": true
            \\  }}
            \\}}
        , .{
            address,
            balance_str,
            @as(u32, @bitCast(account.flags)),
            account.owner_count,
            account.sequence,
            current_ledger.sequence,
        });
    }

    /// ledger - Get information about a ledger
    /// WEEK 3 DAY 15: Fixed to match rippled format (full hex hashes, all fields)
    pub fn ledgerInfo(self: *RpcMethods, ledger_index: ?types.LedgerSequence) ![]u8 {
        const ledger_seq = ledger_index orelse self.ledger_manager.getCurrentLedger().sequence;
        const ledger_data = self.ledger_manager.getLedger(ledger_seq) orelse {
            return try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "error": "lgrNotFound",
                \\  "error_code": 20,
                \\  "error_message": "Ledger not found.",
                \\  "status": "error",
                \\  "validated": true
                \\}}
            , .{});
        };

        // Convert hashes to full hex strings (FIXED Day 15)
        const ledger_hash_hex = try rpc_format.hashToHexAlloc(self.allocator, &ledger_data.hash);
        defer self.allocator.free(ledger_hash_hex);

        const parent_hash_hex = try rpc_format.hashToHexAlloc(self.allocator, &ledger_data.parent_hash);
        defer self.allocator.free(parent_hash_hex);

        const account_hash_hex = try rpc_format.hashToHexAlloc(self.allocator, &ledger_data.account_state_hash);
        defer self.allocator.free(account_hash_hex);

        const tx_hash_hex = try rpc_format.hashToHexAlloc(self.allocator, &ledger_data.transaction_hash);
        defer self.allocator.free(tx_hash_hex);

        // Format total_coins as string (XRPL format)
        const total_coins_str = try std.fmt.allocPrint(self.allocator, "{d}", .{ledger_data.total_coins});
        defer self.allocator.free(total_coins_str);

        // Format ledger_index as string (can be number or string in XRPL)
        const ledger_index_str = try std.fmt.allocPrint(self.allocator, "{d}", .{ledger_data.sequence});
        defer self.allocator.free(ledger_index_str);

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "ledger": {{
            \\      "ledger_index": "{s}",
            \\      "ledger_hash": "{s}",
            \\      "parent_hash": "{s}",
            \\      "account_hash": "{s}",
            \\      "transaction_hash": "{s}",
            \\      "close_time": {d},
            \\      "close_time_resolution": {d},
            \\      "parent_close_time": {d},
            \\      "close_flags": {d},
            \\      "total_coins": "{s}",
            \\      "closed": true
            \\    }},
            \\    "ledger_hash": "{s}",
            \\    "ledger_index": {d},
            \\    "status": "success",
            \\    "validated": true
            \\  }}
            \\}}
        , .{
            ledger_index_str,
            ledger_hash_hex,
            parent_hash_hex,
            account_hash_hex,
            tx_hash_hex,
            ledger_data.close_time,
            ledger_data.close_time_resolution,
            ledger_data.parent_close_time,
            ledger_data.close_flags,
            total_coins_str,
            ledger_hash_hex,
            ledger_data.sequence,
        });
    }

    /// server_info - Get server information
    /// WEEK 3 DAY 15: Fixed to match rippled format (network_id, server_state, etc.)
    pub fn serverInfo(self: *RpcMethods, uptime: u64) ![]u8 {
        const current_ledger = self.ledger_manager.getCurrentLedger();

        // Format ledger hash as full hex string (FIXED Day 15)
        const ledger_hash_hex = try rpc_format.hashToHexAlloc(self.allocator, &current_ledger.hash);
        defer self.allocator.free(ledger_hash_hex);

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "info": {{
            \\      "build_version": "rippled-zig-0.2.0-alpha",
            \\      "complete_ledgers": "1-{d}",
            \\      "hostid": "rippled-zig",
            \\      "network_id": 1,
            \\      "server_state": "full",
            \\      "server_state_duration_us": "{d}000000",
            \\      "peers": 0,
            \\      "uptime": {d},
            \\      "load_factor": 1,
            \\      "validated_ledger": {{
            \\        "age": 0,
            \\        "base_fee_xrp": 0.00001,
            \\        "hash": "{s}",
            \\        "reserve_base_xrp": 1,
            \\        "reserve_inc_xrp": 0.2,
            \\        "seq": {d}
            \\      }},
            \\      "validation_quorum": 4
            \\    }},
            \\    "status": "success"
            \\  }}
            \\}}
        , .{
            current_ledger.sequence,
            uptime,
            uptime,
            ledger_hash_hex,
            current_ledger.sequence,
        });
    }

    /// fee - Get current transaction fee levels
    /// WEEK 3 DAY 15: Added status field to match rippled format
    pub fn fee(self: *RpcMethods) ![]u8 {
        const current_ledger = self.ledger_manager.getCurrentLedger();

        // Format fees as strings (XRPL format)
        const base_fee_str = try std.fmt.allocPrint(self.allocator, "{d}", .{types.MIN_TX_FEE});
        defer self.allocator.free(base_fee_str);

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "current_ledger_size": "0",
            \\    "current_queue_size": "0",
            \\    "drops": {{
            \\      "base_fee": "{s}",
            \\      "median_fee": "{s}",
            \\      "minimum_fee": "{s}",
            \\      "open_ledger_fee": "{s}"
            \\    }},
            \\    "expected_ledger_size": "1000",
            \\    "ledger_current_index": {d},
            \\    "levels": {{
            \\      "median_level": "256",
            \\      "minimum_level": "256",
            \\      "open_ledger_level": "256",
            \\      "reference_level": "256"
            \\    }},
            \\    "max_queue_size": "2000",
            \\    "status": "success"
            \\  }}
            \\}}
        , .{
            base_fee_str,
            base_fee_str,
            base_fee_str,
            base_fee_str,
            current_ledger.sequence,
        });
    }

    /// submit - Submit a signed transaction
    pub fn submit(self: *RpcMethods, tx_blob: []const u8) ![]u8 {
        _ = tx_blob;
        // TODO: Deserialize and validate transaction
        const pending_count = self.tx_processor.getPendingTransactions().len;

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "engine_result": "tesSUCCESS",
            \\    "engine_result_code": 0,
            \\    "engine_result_message": "The transaction was applied.",
            \\    "status": "success",
            \\    "tx_json": {{
            \\      "TransactionType": "Payment"
            \\    }},
            \\    "validated": false,
            \\    "kept": true,
            \\    "queued": {d}
            \\  }}
            \\}}
        , .{pending_count});
    }

    /// ledger_current - Get current working ledger index
    pub fn ledgerCurrent(self: *RpcMethods) ![]u8 {
        const current_ledger = self.ledger_manager.getCurrentLedger();

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "ledger_current_index": {d}
            \\  }}
            \\}}
        , .{current_ledger.sequence});
    }

    /// ledger_closed - Get most recently closed ledger
    /// WEEK 3 DAY 15: Fixed to use full hex hash string
    pub fn ledgerClosed(self: *RpcMethods) ![]u8 {
        const current_ledger = self.ledger_manager.getCurrentLedger();

        // Format hash as full hex string (FIXED Day 15)
        const ledger_hash_hex = try rpc_format.hashToHexAlloc(self.allocator, &current_ledger.hash);
        defer self.allocator.free(ledger_hash_hex);

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "ledger_hash": "{s}",
            \\    "ledger_index": {d},
            \\    "status": "success"
            \\  }}
            \\}}
        , .{
            ledger_hash_hex,
            current_ledger.sequence,
        });
    }

    /// ping - Health check
    pub fn ping(self: *RpcMethods) ![]u8 {
        return try self.allocator.dupe(u8,
            \\{
            \\  "result": {}
            \\}
        );
    }

    /// random - Generate random number
    pub fn random(self: *RpcMethods) ![]u8 {
        var random_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "random": "{any}"
            \\  }}
            \\}}
        , .{random_bytes[0..8]});
    }

    /// agent_status - expose machine-oriented operational state for autonomous controllers
    pub fn agentStatus(self: *RpcMethods, uptime: u64) ![]u8 {
        const current_ledger = self.ledger_manager.getCurrentLedger();
        const pending_count = self.tx_processor.getPendingTransactions().len;

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "status": "success",
            \\    "agent_control": {{
            \\      "api_version": 1,
            \\      "mode": "research",
            \\      "strict_crypto_required": {s}
            \\    }},
            \\    "node_state": {{
            \\      "uptime": {d},
            \\      "validated_ledger_seq": {d},
            \\      "pending_transactions": {d},
            \\      "max_peers": {d},
            \\      "allow_unl_updates": {s}
            \\    }}
            \\  }}
            \\}}
        , .{
            if (self.agent_config.strict_crypto_required) "true" else "false",
            uptime,
            current_ledger.sequence,
            pending_count,
            self.agent_config.max_peers,
            if (self.agent_config.allow_unl_updates) "true" else "false",
        });
    }

    /// agent_config_get - retrieve control-plane configuration
    pub fn agentConfigGet(self: *RpcMethods) ![]u8 {
        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "status": "success",
            \\    "config": {{
            \\      "max_peers": {d},
            \\      "fee_multiplier": {d},
            \\      "strict_crypto_required": {s},
            \\      "allow_unl_updates": {s}
            \\    }}
            \\  }}
            \\}}
        , .{
            self.agent_config.max_peers,
            self.agent_config.fee_multiplier,
            if (self.agent_config.strict_crypto_required) "true" else "false",
            if (self.agent_config.allow_unl_updates) "true" else "false",
        });
    }

    fn parseBoolLiteral(value: []const u8) !bool {
        if (std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "false")) return false;
        return error.InvalidBooleanValue;
    }

    /// agent_config_set - allowlisted mutable knobs for autonomous control loops
    pub fn agentConfigSet(self: *RpcMethods, key: []const u8, value: []const u8) ![]u8 {
        if (std.mem.eql(u8, key, "max_peers")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidConfigValue;
            if (parsed < 5 or parsed > 200) return error.ConfigValueOutOfRange;
            self.agent_config.max_peers = parsed;
        } else if (std.mem.eql(u8, key, "fee_multiplier")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidConfigValue;
            if (parsed < 1 or parsed > 100) return error.ConfigValueOutOfRange;
            self.agent_config.fee_multiplier = parsed;
        } else if (std.mem.eql(u8, key, "strict_crypto_required")) {
            self.agent_config.strict_crypto_required = parseBoolLiteral(value) catch return error.InvalidConfigValue;
        } else if (std.mem.eql(u8, key, "allow_unl_updates")) {
            self.agent_config.allow_unl_updates = parseBoolLiteral(value) catch return error.InvalidConfigValue;
        } else {
            return error.UnsupportedConfigKey;
        }

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "status": "success",
            \\    "updated": {{
            \\      "key": "{s}",
            \\      "value": "{s}"
            \\    }}
            \\  }}
            \\}}
        , .{ key, value });
    }
};

test "rpc methods initialization" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const methods = RpcMethods.init(allocator, &lm, &state, &processor);
    _ = methods;
}

test "server info method" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = RpcMethods.init(allocator, &lm, &state, &processor);

    const result = try methods.serverInfo(12345);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "rippled-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "12345") != null);
}

test "agent control config set/get and status" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = RpcMethods.init(allocator, &lm, &state, &processor);

    const set_res = try methods.agentConfigSet("max_peers", "33");
    defer allocator.free(set_res);
    try std.testing.expect(std.mem.indexOf(u8, set_res, "\"status\": \"success\"") != null);

    const get_res = try methods.agentConfigGet();
    defer allocator.free(get_res);
    try std.testing.expect(std.mem.indexOf(u8, get_res, "\"max_peers\": 33") != null);

    const status_res = try methods.agentStatus(42);
    defer allocator.free(status_res);
    try std.testing.expect(std.mem.indexOf(u8, status_res, "\"api_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_res, "\"max_peers\": 33") != null);
}

test "agent config set rejects unsupported key" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = RpcMethods.init(allocator, &lm, &state, &processor);

    try std.testing.expectError(error.UnsupportedConfigKey, methods.agentConfigSet("evil_key", "1"));
}
