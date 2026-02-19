const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");
const transaction = @import("transaction.zig");
const base58 = @import("base58.zig");
const rpc_format = @import("rpc_format.zig");

/// Complete RPC method implementations
pub const RpcMethods = struct {
    pub const ControlProfile = enum {
        research,
        production,
    };

    pub const AgentControlConfig = struct {
        profile: ControlProfile = .research,
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

    pub fn currentProfile(self: *const RpcMethods) ControlProfile {
        return self.agent_config.profile;
    }

    pub fn isMethodAllowedForProfile(self: *const RpcMethods, method: []const u8) bool {
        return switch (self.agent_config.profile) {
            .research => true,
            .production => blk: {
                const allowed = [_][]const u8{
                    "server_info",
                    "ledger",
                    "ledger_current",
                    "fee",
                    "ping",
                    "agent_status",
                    "agent_config_get",
                    "account_info",
                };
                for (allowed) |name| {
                    if (std.mem.eql(u8, method, name)) break :blk true;
                }
                break :blk false;
            },
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
        const tx = try parseMinimalSubmitTxBlob(tx_blob);
        const validation = try self.tx_processor.validateTransaction(&tx, self.account_state);

        if (validation != .tes_success) {
            const engine = switch (validation) {
                .tel_local_error => "telLOCAL_ERROR",
                .tem_malformed => "temMALFORMED",
                .ter_retry => "terRETRY",
                .tec_claim => "tecCLAIM",
                .tef_failure => "tefFAILURE",
                .tes_success, .success => "tesSUCCESS",
            };

            return try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "result": {{
                \\    "engine_result": "{s}",
                \\    "engine_result_code": -1,
                \\    "engine_result_message": "Transaction failed validation.",
                \\    "status": "error",
                \\    "validated": false
                \\  }}
                \\}}
            , .{engine});
        }

        // Minimal local apply path: update sender account sequence and deduct fee.
        var account = self.account_state.getAccount(tx.account) orelse return error.AccountNotFound;
        account.sequence += 1;
        account.balance -= tx.fee;
        try self.account_state.putAccount(account);

        try self.tx_processor.submitTransaction(tx);
        const pending_count = self.tx_processor.getPendingTransactions().len;

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "engine_result": "tesSUCCESS",
            \\    "engine_result_code": 0,
            \\    "engine_result_message": "The transaction was applied.",
            \\    "status": "success",
            \\    "tx_json": {{
            \\      "TransactionType": "{s}",
            \\      "Fee": "{d}",
            \\      "Sequence": {d}
            \\    }},
            \\    "validated": false,
            \\    "kept": true,
            \\    "queued": {d}
            \\  }}
            \\}}
        , .{ @tagName(tx.tx_type), tx.fee, tx.sequence, pending_count });
    }

    fn parseMinimalSubmitTxBlob(tx_blob_hex: []const u8) !types.Transaction {
        // Minimal wire format:
        // [0..2): u16 tx_type (BE)
        // [2..22): account (20 bytes)
        // [22..30): fee (u64 BE)
        // [30..34): sequence (u32 BE)
        if (tx_blob_hex.len == 0 or tx_blob_hex.len % 2 != 0) return error.InvalidTxBlob;

        var raw: [34]u8 = undefined;
        if (tx_blob_hex.len != raw.len * 2) return error.InvalidTxBlob;
        _ = std.fmt.hexToBytes(&raw, tx_blob_hex) catch return error.InvalidTxBlob;

        const tx_type_raw = std.mem.readInt(u16, raw[0..2], .big);
        const tx_type = std.meta.intToEnum(types.TransactionType, tx_type_raw) catch return error.UnsupportedTransactionType;

        var account: types.AccountID = undefined;
        @memcpy(&account, raw[2..22]);

        const tx_fee = std.mem.readInt(u64, raw[22..30], .big);
        const sequence = std.mem.readInt(u32, raw[30..34], .big);

        return types.Transaction{
            .tx_type = tx_type,
            .account = account,
            .fee = tx_fee,
            .sequence = sequence,
            .signing_pub_key = null,
            .txn_signature = null,
            .signers = null,
        };
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
        const mode = switch (self.agent_config.profile) {
            .research => "research",
            .production => "production",
        };

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "status": "success",
            \\    "agent_control": {{
            \\      "api_version": 1,
            \\      "mode": "{s}",
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
            mode,
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
        const profile = switch (self.agent_config.profile) {
            .research => "research",
            .production => "production",
        };

        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "result": {{
            \\    "status": "success",
            \\    "config": {{
            \\      "profile": "{s}",
            \\      "max_peers": {d},
            \\      "fee_multiplier": {d},
            \\      "strict_crypto_required": {s},
            \\      "allow_unl_updates": {s}
            \\    }}
            \\  }}
            \\}}
        , .{
            profile,
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

    fn parseProfileLiteral(value: []const u8) !ControlProfile {
        if (std.mem.eql(u8, value, "research")) return .research;
        if (std.mem.eql(u8, value, "production")) return .production;
        return error.InvalidProfileValue;
    }

    fn validateProductionInvariants(config: AgentControlConfig) !void {
        if (!config.strict_crypto_required) return error.PolicyViolation;
        if (config.allow_unl_updates) return error.PolicyViolation;
        if (config.fee_multiplier > 5) return error.PolicyViolation;
        if (config.max_peers > 100) return error.PolicyViolation;
    }

    /// agent_config_set - allowlisted mutable knobs for autonomous control loops
    pub fn agentConfigSet(self: *RpcMethods, key: []const u8, value: []const u8) ![]u8 {
        var next = self.agent_config;

        if (std.mem.eql(u8, key, "max_peers")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidConfigValue;
            if (parsed < 5 or parsed > 200) return error.ConfigValueOutOfRange;
            next.max_peers = parsed;
        } else if (std.mem.eql(u8, key, "fee_multiplier")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidConfigValue;
            if (parsed < 1 or parsed > 100) return error.ConfigValueOutOfRange;
            next.fee_multiplier = parsed;
        } else if (std.mem.eql(u8, key, "strict_crypto_required")) {
            next.strict_crypto_required = parseBoolLiteral(value) catch return error.InvalidConfigValue;
        } else if (std.mem.eql(u8, key, "allow_unl_updates")) {
            next.allow_unl_updates = parseBoolLiteral(value) catch return error.InvalidConfigValue;
        } else if (std.mem.eql(u8, key, "profile")) {
            next.profile = parseProfileLiteral(value) catch return error.InvalidConfigValue;
        } else {
            return error.UnsupportedConfigKey;
        }

        // Enforce policy constraints for production profile.
        if (next.profile == .production) {
            validateProductionInvariants(next) catch |err| switch (err) {
                error.PolicyViolation => {
                    // Distinguish entering production from violating an active production profile.
                    if (self.agent_config.profile != .production and next.profile == .production) {
                        return error.UnsafeProfileTransition;
                    }
                    return error.PolicyViolation;
                },
                else => return err,
            };
        }

        self.agent_config = next;

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
    try std.testing.expect(std.mem.indexOf(u8, get_res, "\"profile\": \"research\"") != null);
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

fn makeMinimalSubmitBlob(
    allocator: std.mem.Allocator,
    tx_type: types.TransactionType,
    account: types.AccountID,
    fee: types.Drops,
    sequence: u32,
) ![]u8 {
    var raw: [34]u8 = undefined;
    std.mem.writeInt(u16, raw[0..2], @intFromEnum(tx_type), .big);
    @memcpy(raw[2..22], &account);
    std.mem.writeInt(u64, raw[22..30], fee, .big);
    std.mem.writeInt(u32, raw[30..34], sequence, .big);
    const encoded = std.fmt.bytesToHex(raw, .upper);
    return try allocator.dupe(u8, &encoded);
}

test "submit minimal path validates applies and queues transaction" {
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
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 7,
    });

    var methods = RpcMethods.init(allocator, &lm, &state, &processor);
    const blob = try makeMinimalSubmitBlob(allocator, .payment, account, types.MIN_TX_FEE, 7);
    defer allocator.free(blob);

    const res = try methods.submit(blob);
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"status\": \"success\"") != null);
    try std.testing.expectEqual(@as(usize, 1), processor.getPendingTransactions().len);

    const updated = state.getAccount(account).?;
    try std.testing.expectEqual(@as(u32, 8), updated.sequence);
    try std.testing.expectEqual(@as(types.Drops, 1000 * types.XRP - types.MIN_TX_FEE), updated.balance);
}

test "submit minimal path returns validation error on bad sequence" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const account = [_]u8{2} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 10,
    });

    var methods = RpcMethods.init(allocator, &lm, &state, &processor);
    const blob = try makeMinimalSubmitBlob(allocator, .payment, account, types.MIN_TX_FEE, 9);
    defer allocator.free(blob);

    const res = try methods.submit(blob);
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"status\": \"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"engine_result\": \"terRETRY\"") != null);
    try std.testing.expectEqual(@as(usize, 0), processor.getPendingTransactions().len);
}

test "agent control profile production policy is enforced" {
    const allocator = std.testing.allocator;
    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    var methods = RpcMethods.init(allocator, &lm, &state, &processor);

    // Unsafe transition: cannot enter production with strict crypto disabled.
    const set_strict_false = try methods.agentConfigSet("strict_crypto_required", "false");
    defer allocator.free(set_strict_false);
    try std.testing.expectError(error.UnsafeProfileTransition, methods.agentConfigSet("profile", "production"));

    // Restore safe state and enter production.
    const set_strict_true = try methods.agentConfigSet("strict_crypto_required", "true");
    defer allocator.free(set_strict_true);
    const set_prod = try methods.agentConfigSet("profile", "production");
    defer allocator.free(set_prod);
    try std.testing.expect(std.mem.indexOf(u8, set_prod, "\"status\": \"success\"") != null);

    // In production profile, unsafe mutations are blocked.
    try std.testing.expectError(error.PolicyViolation, methods.agentConfigSet("allow_unl_updates", "true"));
    try std.testing.expectError(error.PolicyViolation, methods.agentConfigSet("strict_crypto_required", "false"));
    try std.testing.expectError(error.PolicyViolation, methods.agentConfigSet("fee_multiplier", "99"));
}
