const std = @import("std");
const ledger = @import("ledger.zig");
const rpc = @import("rpc.zig");
const rpc_methods = @import("rpc_methods.zig");
const secp256k1 = @import("secp256k1.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

const Fixture = struct {
    server_build_version: []const u8,
    server_state: []const u8,
    server_peers: i64,
    server_hash: []const u8,
    server_seq: i64,
    fee_status: []const u8,
    fee_base: []const u8,
    fee_median: []const u8,
    fee_minimum: []const u8,
    fee_ledger_index: i64,
    ledger_hash: []const u8,
    ledger_index: i64,
    ledger_account_hash: []const u8,
    ledger_parent_hash: []const u8,
    ledger_transaction_hash: []const u8,
    ledger_total_coins: []const u8,
    ledger_close_time: i64,
    ledger_parent_close_time: i64,
    ledger_close_time_resolution: i64,
    ledger_close_flags: i64,
    ledger_transactions_count: usize,
    ledger_tx0_account: []const u8,
    ledger_tx0_type: []const u8,
    ledger_tx0_fee: []const u8,
    ledger_tx0_sequence: i64,
    account_status: []const u8,
    account_error_code: i64,
    account_validated: bool,
    secp_tx_hash: []const u8,
    secp_pub_key: []const u8,
    secp_signature: []const u8,
    secp_r: []const u8,
    secp_s: []const u8,
};

const SecpStrictVector = struct {
    name: []const u8,
    signing_prefix_hex: []const u8,
    canonical_hex: []const u8,
    signing_hash_hex: []const u8,
    pubkey_hex: []const u8,
    signature_hex: []const u8,
};

const SecpVerifyVector = struct {
    name: []const u8,
    signing_hash_hex: []const u8,
    pubkey_hex: []const u8,
    signature_hex: []const u8,
};

fn getObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => error.ExpectedObject,
    };
}

fn getField(obj: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return obj.get(key) orelse error.MissingExpectedField;
}

fn getString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn getInteger(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |n| n,
        else => error.ExpectedInteger,
    };
}

fn getIntegerFlexible(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |n| n,
        .string => |s| try std.fmt.parseInt(i64, s, 10),
        else => error.ExpectedInteger,
    };
}

fn getBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.ExpectedBool,
    };
}

fn ensureRequiredFields(obj: std.json.ObjectMap, fields: []const std.json.Value) !void {
    for (fields) |field_value| {
        const field = try getString(field_value);
        if (obj.get(field) == null) return error.MissingExpectedField;
    }
}

fn assertAgentStatusSchema(status_payload: []const u8, schema_payload: []const u8, allocator: std.mem.Allocator) !void {
    var status_parsed = try std.json.parseFromSlice(std.json.Value, allocator, status_payload, .{});
    defer status_parsed.deinit();
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, allocator, schema_payload, .{});
    defer schema_parsed.deinit();

    const status_root = try getObject(status_parsed.value);
    const status_result = try getObject(try getField(status_root, "result"));
    const status_agent = try getObject(try getField(status_result, "agent_control"));
    const status_node = try getObject(try getField(status_result, "node_state"));

    const schema_root = try getObject(schema_parsed.value);
    const required_fields = try getObject(try getField(schema_root, "required_fields"));
    const expected_values = try getObject(try getField(schema_root, "expected_values"));

    const req_result = switch (try getField(required_fields, "result")) {
        .array => |arr| arr.items,
        else => return error.ExpectedArray,
    };
    const req_agent = switch (try getField(required_fields, "agent_control")) {
        .array => |arr| arr.items,
        else => return error.ExpectedArray,
    };
    const req_node = switch (try getField(required_fields, "node_state")) {
        .array => |arr| arr.items,
        else => return error.ExpectedArray,
    };
    try ensureRequiredFields(status_result, req_result);
    try ensureRequiredFields(status_agent, req_agent);
    try ensureRequiredFields(status_node, req_node);

    const expected_status = try getString(try getField(expected_values, "status"));
    const actual_status = try getString(try getField(status_result, "status"));
    if (!std.mem.eql(u8, actual_status, expected_status)) return error.AgentStatusMismatch;

    const expected_api_version = try getInteger(try getField(expected_values, "api_version"));
    const actual_api_version = try getInteger(try getField(status_agent, "api_version"));
    if (actual_api_version != expected_api_version) return error.AgentStatusMismatch;

    const expected_mode = try getString(try getField(expected_values, "mode"));
    const actual_mode = try getString(try getField(status_agent, "mode"));
    if (!std.mem.eql(u8, actual_mode, expected_mode)) return error.AgentStatusMismatch;

    const expected_strict_crypto = try getBool(try getField(expected_values, "strict_crypto_required"));
    const actual_strict_crypto = try getBool(try getField(status_agent, "strict_crypto_required"));
    if (actual_strict_crypto != expected_strict_crypto) return error.AgentStatusMismatch;

    const expected_max_peers = try getInteger(try getField(expected_values, "max_peers"));
    const actual_max_peers = try getInteger(try getField(status_node, "max_peers"));
    if (actual_max_peers != expected_max_peers) return error.AgentStatusMismatch;

    const expected_allow_unl = try getBool(try getField(expected_values, "allow_unl_updates"));
    const actual_allow_unl = try getBool(try getField(status_node, "allow_unl_updates"));
    if (actual_allow_unl != expected_allow_unl) return error.AgentStatusMismatch;
}

fn assertAgentConfigGetSchema(config_payload: []const u8, schema_payload: []const u8, allocator: std.mem.Allocator) !void {
    var config_parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_payload, .{});
    defer config_parsed.deinit();
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, allocator, schema_payload, .{});
    defer schema_parsed.deinit();

    const config_root = try getObject(config_parsed.value);
    const config_result = try getObject(try getField(config_root, "result"));
    const config = try getObject(try getField(config_result, "config"));

    const schema_root = try getObject(schema_parsed.value);
    const required_fields = try getObject(try getField(schema_root, "required_fields"));
    const expected_values = try getObject(try getField(schema_root, "expected_values"));

    const req_result = switch (try getField(required_fields, "result")) {
        .array => |arr| arr.items,
        else => return error.ExpectedArray,
    };
    const req_config = switch (try getField(required_fields, "config")) {
        .array => |arr| arr.items,
        else => return error.ExpectedArray,
    };

    try ensureRequiredFields(config_result, req_result);
    try ensureRequiredFields(config, req_config);

    const expected_status = try getString(try getField(expected_values, "status"));
    const actual_status = try getString(try getField(config_result, "status"));
    if (!std.mem.eql(u8, actual_status, expected_status)) return error.AgentConfigMismatch;

    const expected_profile = try getString(try getField(expected_values, "profile"));
    const actual_profile = try getString(try getField(config, "profile"));
    if (!std.mem.eql(u8, actual_profile, expected_profile)) return error.AgentConfigMismatch;

    const expected_max_peers = try getInteger(try getField(expected_values, "max_peers"));
    const actual_max_peers = try getInteger(try getField(config, "max_peers"));
    if (actual_max_peers != expected_max_peers) return error.AgentConfigMismatch;

    const expected_fee_multiplier = try getInteger(try getField(expected_values, "fee_multiplier"));
    const actual_fee_multiplier = try getInteger(try getField(config, "fee_multiplier"));
    if (actual_fee_multiplier != expected_fee_multiplier) return error.AgentConfigMismatch;

    const expected_strict_crypto = try getBool(try getField(expected_values, "strict_crypto_required"));
    const actual_strict_crypto = try getBool(try getField(config, "strict_crypto_required"));
    if (actual_strict_crypto != expected_strict_crypto) return error.AgentConfigMismatch;

    const expected_allow_unl = try getBool(try getField(expected_values, "allow_unl_updates"));
    const actual_allow_unl = try getBool(try getField(config, "allow_unl_updates"));
    if (actual_allow_unl != expected_allow_unl) return error.AgentConfigMismatch;
}

fn assertRpcLiveMethodsContracts(
    account_info_payload: []const u8,
    submit_payload: []const u8,
    ping_payload: []const u8,
    ledger_current_payload: []const u8,
    schema_payload: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var account_parsed = try std.json.parseFromSlice(std.json.Value, allocator, account_info_payload, .{});
    defer account_parsed.deinit();
    var submit_parsed = try std.json.parseFromSlice(std.json.Value, allocator, submit_payload, .{});
    defer submit_parsed.deinit();
    var ping_parsed = try std.json.parseFromSlice(std.json.Value, allocator, ping_payload, .{});
    defer ping_parsed.deinit();
    var ledger_current_parsed = try std.json.parseFromSlice(std.json.Value, allocator, ledger_current_payload, .{});
    defer ledger_current_parsed.deinit();
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, allocator, schema_payload, .{});
    defer schema_parsed.deinit();

    const schema_root = try getObject(schema_parsed.value);
    const methods = try getObject(try getField(schema_root, "methods"));

    // account_info
    {
        const account_schema = try getObject(try getField(methods, "account_info"));
        const account_root = try getObject(account_parsed.value);
        const req_fields = switch (try getField(account_schema, "required_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(account_root, req_fields);

        const account_result = try getObject(try getField(account_root, "result"));
        const req_result_fields = switch (try getField(account_schema, "required_result_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(account_result, req_result_fields);

        const account_data = try getObject(try getField(account_result, "account_data"));
        const req_account_fields = switch (try getField(account_schema, "required_account_data_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(account_data, req_account_fields);

        const expected_status = try getString(try getField(account_schema, "expected_status"));
        const actual_status = try getString(try getField(account_result, "status"));
        if (!std.mem.eql(u8, actual_status, expected_status)) return error.RpcContractMismatch;

        const expected_validated = try getBool(try getField(account_schema, "expected_validated"));
        const actual_validated = try getBool(try getField(account_result, "validated"));
        if (actual_validated != expected_validated) return error.RpcContractMismatch;
    }

    // submit
    {
        const submit_schema = try getObject(try getField(methods, "submit"));
        const submit_root = try getObject(submit_parsed.value);
        const req_fields = switch (try getField(submit_schema, "required_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(submit_root, req_fields);

        const submit_result = try getObject(try getField(submit_root, "result"));
        const req_result_fields = switch (try getField(submit_schema, "required_result_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(submit_result, req_result_fields);

        const expected_status = try getString(try getField(submit_schema, "expected_status"));
        const actual_status = try getString(try getField(submit_result, "status"));
        if (!std.mem.eql(u8, actual_status, expected_status)) return error.RpcContractMismatch;

        const expected_engine_result = try getString(try getField(submit_schema, "expected_engine_result"));
        const actual_engine_result = try getString(try getField(submit_result, "engine_result"));
        if (!std.mem.eql(u8, actual_engine_result, expected_engine_result)) return error.RpcContractMismatch;

        const submit_tx_json = try getObject(try getField(submit_result, "tx_json"));
        const req_tx_json_fields = switch (try getField(submit_schema, "required_tx_json_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(submit_tx_json, req_tx_json_fields);

        const expected_tx_type = try getString(try getField(submit_schema, "expected_tx_type"));
        const actual_tx_type = try getString(try getField(submit_tx_json, "TransactionType"));
        if (!std.mem.eql(u8, actual_tx_type, expected_tx_type)) return error.RpcContractMismatch;
    }

    // ping
    {
        const ping_schema = try getObject(try getField(methods, "ping"));
        const ping_root = try getObject(ping_parsed.value);
        const req_fields = switch (try getField(ping_schema, "required_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(ping_root, req_fields);
    }

    // ledger_current
    {
        const ledger_current_schema = try getObject(try getField(methods, "ledger_current"));
        const ledger_current_root = try getObject(ledger_current_parsed.value);
        const req_fields = switch (try getField(ledger_current_schema, "required_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(ledger_current_root, req_fields);

        const ledger_current_result = try getObject(try getField(ledger_current_root, "result"));
        const req_result_fields = switch (try getField(ledger_current_schema, "required_result_fields")) {
            .array => |arr| arr.items,
            else => return error.ExpectedArray,
        };
        try ensureRequiredFields(ledger_current_result, req_result_fields);
    }
}

fn assertRpcLiveNegativeContracts(server: *rpc.RpcServer, schema_payload: []const u8, allocator: std.mem.Allocator) !void {
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, allocator, schema_payload, .{});
    defer schema_parsed.deinit();
    const schema_root = try getObject(schema_parsed.value);
    const cases = try getObject(try getField(schema_root, "cases"));

    const research_cases = [_][]const u8{
        "account_info_missing_param",
        "account_info_invalid_account",
        "submit_missing_blob",
        "submit_empty_blob",
        "submit_non_hex_blob",
        "submit_invalid_blob_structure",
        "submit_missing_destination_account",
        "submit_insufficient_payment_balance",
    };

    for (research_cases) |case_name| {
        const case_obj = switch (cases.get(case_name) orelse return error.MissingExpectedField) {
            .object => |obj| obj,
            else => return error.ExpectedObject,
        };
        const request = try getString(case_obj.get("request") orelse return error.MissingExpectedField);
        const expected_error = try getString(case_obj.get("expected_error") orelse return error.MissingExpectedField);
        const response = try server.handleJsonRpcRequest(request);
        defer allocator.free(response);

        const expected_snippet = try std.fmt.allocPrint(allocator, "\"error\": \"{s}\"", .{expected_error});
        defer allocator.free(expected_snippet);
        if (std.mem.indexOf(u8, response, expected_snippet) == null) return error.RpcContractMismatch;
    }

    const to_prod = try server.handleJsonRpcRequest("{\"method\":\"agent_config_set\",\"params\":{\"key\":\"profile\",\"value\":\"production\"}}");
    defer allocator.free(to_prod);
    if (std.mem.indexOf(u8, to_prod, "\"status\": \"success\"") == null) return error.RpcContractMismatch;

    const blocked_case = switch (cases.get("submit_blocked_in_production") orelse return error.MissingExpectedField) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };
    const blocked_request = try getString(blocked_case.get("request") orelse return error.MissingExpectedField);
    const blocked_expected = try getString(blocked_case.get("expected_error") orelse return error.MissingExpectedField);
    const blocked_response = try server.handleJsonRpcRequest(blocked_request);
    defer allocator.free(blocked_response);

    const blocked_snippet = try std.fmt.allocPrint(allocator, "\"error\": \"{s}\"", .{blocked_expected});
    defer allocator.free(blocked_snippet);
    if (std.mem.indexOf(u8, blocked_response, blocked_snippet) == null) return error.RpcContractMismatch;
}

fn makeMinimalSubmitBlob(
    allocator: std.mem.Allocator,
    tx_type: types.TransactionType,
    account: types.AccountID,
    fee: types.Drops,
    sequence: u32,
    destination: ?types.AccountID,
    amount: ?types.Drops,
) ![]u8 {
    const hex_alphabet = "0123456789ABCDEF";
    var raw: [62]u8 = undefined;
    std.mem.writeInt(u16, raw[0..2], @intFromEnum(tx_type), .big);
    @memcpy(raw[2..22], &account);
    std.mem.writeInt(u64, raw[22..30], fee, .big);
    std.mem.writeInt(u32, raw[30..34], sequence, .big);
    var used: usize = 34;
    if (tx_type == .payment) {
        const dest = destination orelse return error.MissingPaymentDestination;
        const drops = amount orelse return error.MissingPaymentAmount;
        @memcpy(raw[34..54], &dest);
        std.mem.writeInt(u64, raw[54..62], drops, .big);
        used = 62;
    }
    const encoded = try allocator.alloc(u8, used * 2);
    errdefer allocator.free(encoded);
    for (raw[0..used], 0..) |b, i| {
        encoded[i * 2] = hex_alphabet[b >> 4];
        encoded[i * 2 + 1] = hex_alphabet[b & 0x0F];
    }
    return encoded;
}

fn parseHex32(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidHexLength;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

fn parseHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHexLength;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn isStrictCryptoEnabled() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "GATE_C_STRICT_CRYPTO") catch return false;
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, "true");
}

fn expectMismatch(actual: []const u8, expected: []const u8) !void {
    if (std.mem.eql(u8, actual, expected)) return error.TamperControlDidNotTrigger;
}

fn assertAccountInfoLocal(payload: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));
    const account_data = try getObject(try getField(result, "account_data"));

    const account = try getString(try getField(account_data, "Account"));
    if (account.len < 25) return error.InvalidAccountFormat;

    const balance = try getString(try getField(account_data, "Balance"));
    if (!std.mem.eql(u8, balance, "123000000")) return error.UnexpectedAccountBalance;

    const sequence = try getInteger(try getField(account_data, "Sequence"));
    if (sequence != 7) return error.UnexpectedAccountSequence;

    const status = try getString(try getField(result, "status"));
    if (!std.mem.eql(u8, status, "success")) return error.UnexpectedStatus;

    const validated = try getBool(try getField(result, "validated"));
    if (!validated) return error.UnexpectedValidatedFlag;
}

fn assertServerInfoLocal(payload: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));
    const info = try getObject(try getField(result, "info"));
    const validated = try getObject(try getField(info, "validated_ledger"));

    const build_version = try getString(try getField(info, "build_version"));
    if (std.mem.indexOf(u8, build_version, "rippled-zig-") == null) return error.UnexpectedBuildVersion;

    const network_id = try getInteger(try getField(info, "network_id"));
    if (network_id != 1) return error.UnexpectedNetworkId;

    const server_state = try getString(try getField(info, "server_state"));
    if (!std.mem.eql(u8, server_state, "full")) return error.UnexpectedServerState;

    const hash = try getString(try getField(validated, "hash"));
    if (hash.len != 64) return error.InvalidLedgerHashLength;
}

fn assertFeeLocal(payload: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));
    const drops = try getObject(try getField(result, "drops"));

    const base_fee = try getString(try getField(drops, "base_fee"));
    if (!std.mem.eql(u8, base_fee, "10")) return error.UnexpectedBaseFee;

    const median_fee = try getString(try getField(drops, "median_fee"));
    if (!std.mem.eql(u8, median_fee, "10")) return error.UnexpectedMedianFee;

    const status = try getString(try getField(result, "status"));
    if (!std.mem.eql(u8, status, "success")) return error.UnexpectedStatus;
}

fn assertServerFixture(payload: []const u8, allocator: std.mem.Allocator, fixture: Fixture) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));
    const info = try getObject(try getField(result, "info"));
    const validated = try getObject(try getField(info, "validated_ledger"));

    const status = try getString(try getField(result, "status"));
    if (!std.mem.eql(u8, status, "success")) return error.UnexpectedFixtureStatus;

    const network_id = try getInteger(try getField(info, "network_id"));
    if (network_id != 1) return error.UnexpectedFixtureNetworkId;

    const build_version = try getString(try getField(info, "build_version"));
    if (!std.mem.eql(u8, build_version, fixture.server_build_version)) return error.ServerFixtureBuildVersionMismatch;

    const server_state = try getString(try getField(info, "server_state"));
    if (!std.mem.eql(u8, server_state, fixture.server_state)) return error.ServerFixtureStateMismatch;

    const peers = try getInteger(try getField(info, "peers"));
    if (peers != fixture.server_peers) return error.ServerFixturePeersMismatch;

    const hash = try getString(try getField(validated, "hash"));
    if (!std.mem.eql(u8, hash, fixture.server_hash)) return error.ServerFixtureHashMismatch;

    const seq = try getInteger(try getField(validated, "seq"));
    if (seq != fixture.server_seq) return error.ServerFixtureSeqMismatch;
}

fn assertFeeFixture(payload: []const u8, allocator: std.mem.Allocator, fixture: Fixture) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));
    const drops = try getObject(try getField(result, "drops"));

    const status = try getString(try getField(result, "status"));
    if (!std.mem.eql(u8, status, fixture.fee_status)) return error.UnexpectedFixtureStatus;

    const base_fee = try getString(try getField(drops, "base_fee"));
    if (!std.mem.eql(u8, base_fee, fixture.fee_base)) return error.FeeFixtureBaseMismatch;

    const median_fee = try getString(try getField(drops, "median_fee"));
    if (!std.mem.eql(u8, median_fee, fixture.fee_median)) return error.FeeFixtureMedianMismatch;

    const minimum_fee = try getString(try getField(drops, "minimum_fee"));
    if (!std.mem.eql(u8, minimum_fee, fixture.fee_minimum)) return error.FeeFixtureMinimumMismatch;

    const ledger_index = try getIntegerFlexible(try getField(result, "ledger_current_index"));
    if (ledger_index != fixture.fee_ledger_index) return error.FeeFixtureLedgerIndexMismatch;
}

fn assertAccountFixture(payload: []const u8, allocator: std.mem.Allocator, fixture: Fixture) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));

    if (result.get("account_data")) |account_data_value| {
        const account_data = try getObject(account_data_value);
        _ = try getString(try getField(account_data, "Account"));
        return;
    }

    const status = try getString(try getField(result, "status"));
    if (!std.mem.eql(u8, status, fixture.account_status)) return error.AccountFixtureExpectedError;

    const error_code = try getInteger(try getField(result, "error_code"));
    if (error_code != fixture.account_error_code) return error.AccountFixtureErrorCodeMismatch;

    const validated = try getBool(try getField(result, "validated"));
    if (validated != fixture.account_validated) return error.AccountFixtureValidatedMismatch;

    const account_ledger_hash = try getString(try getField(result, "ledger_hash"));
    if (!std.mem.eql(u8, account_ledger_hash, fixture.ledger_hash)) return error.AccountFixtureLedgerHashMismatch;

    const account_ledger_index = try getIntegerFlexible(try getField(result, "ledger_index"));
    if (account_ledger_index != fixture.ledger_index) return error.AccountFixtureLedgerIndexMismatch;
}

fn assertLedgerFixture(payload: []const u8, allocator: std.mem.Allocator, fixture: Fixture) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));
    const ledger_obj = try getObject(try getField(result, "ledger"));

    const status = try getString(try getField(result, "status"));
    if (!std.mem.eql(u8, status, "success")) return error.LedgerFixtureStatusMismatch;

    const hash = try getString(try getField(ledger_obj, "ledger_hash"));
    if (!std.mem.eql(u8, hash, fixture.ledger_hash)) return error.LedgerFixtureHashMismatch;

    const index = try getIntegerFlexible(try getField(ledger_obj, "ledger_index"));
    if (index != fixture.ledger_index) return error.LedgerFixtureIndexMismatch;

    const account_hash = try getString(try getField(ledger_obj, "account_hash"));
    if (!std.mem.eql(u8, account_hash, fixture.ledger_account_hash)) return error.LedgerFixtureAccountHashMismatch;

    const parent_hash = try getString(try getField(ledger_obj, "parent_hash"));
    if (!std.mem.eql(u8, parent_hash, fixture.ledger_parent_hash)) return error.LedgerFixtureParentHashMismatch;

    const transaction_hash = try getString(try getField(ledger_obj, "transaction_hash"));
    if (!std.mem.eql(u8, transaction_hash, fixture.ledger_transaction_hash)) return error.LedgerFixtureTransactionHashMismatch;

    const total_coins = try getString(try getField(ledger_obj, "total_coins"));
    if (!std.mem.eql(u8, total_coins, fixture.ledger_total_coins)) return error.LedgerFixtureTotalCoinsMismatch;

    const close_time = try getIntegerFlexible(try getField(ledger_obj, "close_time"));
    if (close_time != fixture.ledger_close_time) return error.LedgerFixtureCloseTimeMismatch;

    const parent_close_time = try getIntegerFlexible(try getField(ledger_obj, "parent_close_time"));
    if (parent_close_time != fixture.ledger_parent_close_time) return error.LedgerFixtureParentCloseTimeMismatch;

    const close_time_resolution = try getIntegerFlexible(try getField(ledger_obj, "close_time_resolution"));
    if (close_time_resolution != fixture.ledger_close_time_resolution) return error.LedgerFixtureCloseTimeResolutionMismatch;

    const close_flags = try getIntegerFlexible(try getField(ledger_obj, "close_flags"));
    if (close_flags != fixture.ledger_close_flags) return error.LedgerFixtureCloseFlagsMismatch;

    const closed = try getBool(try getField(ledger_obj, "closed"));
    if (!closed) return error.LedgerFixtureClosedMismatch;

    const txs_value = try getField(ledger_obj, "transactions");
    const txs = switch (txs_value) {
        .array => |arr| arr,
        else => return error.ExpectedTransactionsArray,
    };
    if (txs.items.len != fixture.ledger_transactions_count) return error.LedgerFixtureTransactionsCountMismatch;
    if (txs.items.len == 0) return error.EmptyTransactions;

    const first_tx = try getObject(txs.items[0]);
    const first_tx_account = try getString(try getField(first_tx, "Account"));
    if (!std.mem.eql(u8, first_tx_account, fixture.ledger_tx0_account)) return error.LedgerFixtureTx0AccountMismatch;

    const first_tx_type = try getString(try getField(first_tx, "TransactionType"));
    if (!std.mem.eql(u8, first_tx_type, fixture.ledger_tx0_type)) return error.LedgerFixtureTx0TypeMismatch;

    const first_tx_fee = try getString(try getField(first_tx, "Fee"));
    if (!std.mem.eql(u8, first_tx_fee, fixture.ledger_tx0_fee)) return error.LedgerFixtureTx0FeeMismatch;

    const first_tx_sequence = try getIntegerFlexible(try getField(first_tx, "Sequence"));
    if (first_tx_sequence != fixture.ledger_tx0_sequence) return error.LedgerFixtureTx0SequenceMismatch;
}

fn assertSecpFixture(payload: []const u8, allocator: std.mem.Allocator, fixture: Fixture) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));
    const ledger_obj = try getObject(try getField(result, "ledger"));
    const txs_value = try getField(ledger_obj, "transactions");
    const txs = switch (txs_value) {
        .array => |arr| arr,
        else => return error.ExpectedTransactionsArray,
    };
    if (txs.items.len == 0) return error.EmptyTransactions;
    const first_tx = try getObject(txs.items[0]);

    const tx_hash = try getString(try getField(first_tx, "hash"));
    if (!std.mem.eql(u8, tx_hash, fixture.secp_tx_hash)) return error.SecpFixtureTxHashMismatch;

    const signing_pub_key = try getString(try getField(first_tx, "SigningPubKey"));
    if (!std.mem.eql(u8, signing_pub_key, fixture.secp_pub_key)) return error.SecpFixturePubKeyMismatch;

    const txn_signature = try getString(try getField(first_tx, "TxnSignature"));
    if (!std.mem.eql(u8, txn_signature, fixture.secp_signature)) return error.SecpFixtureSignatureMismatch;

    const sig_bytes = try parseHexAlloc(allocator, txn_signature);
    defer allocator.free(sig_bytes);
    const parsed_sig = try secp256k1.parseDERSignature(sig_bytes);
    const expected_r = try parseHex32(fixture.secp_r);
    const expected_s = try parseHex32(fixture.secp_s);
    if (!std.mem.eql(u8, &parsed_sig.r, &expected_r)) return error.SecpFixtureRValueMismatch;
    if (!std.mem.eql(u8, &parsed_sig.s, &expected_s)) return error.SecpFixtureSValueMismatch;
}

fn assertNegativeCryptoControls(payload: []const u8, allocator: std.mem.Allocator, fixture: Fixture) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = try getObject(parsed.value);
    const result = try getObject(try getField(root, "result"));
    const ledger_obj = try getObject(try getField(result, "ledger"));
    const txs_value = try getField(ledger_obj, "transactions");
    const txs = switch (txs_value) {
        .array => |arr| arr,
        else => return error.ExpectedTransactionsArray,
    };
    if (txs.items.len == 0) return error.EmptyTransactions;
    const first_tx = try getObject(txs.items[0]);

    const signing_pub_key = try getString(try getField(first_tx, "SigningPubKey"));
    const txn_signature = try getString(try getField(first_tx, "TxnSignature"));

    // Control A: tampered values must not pass strict equality checks.
    var tampered_pubkey = try allocator.dupe(u8, signing_pub_key);
    defer allocator.free(tampered_pubkey);
    tampered_pubkey[tampered_pubkey.len - 1] = if (tampered_pubkey[tampered_pubkey.len - 1] == 'A') 'B' else 'A';
    try expectMismatch(tampered_pubkey, fixture.secp_pub_key);

    var tampered_signature = try allocator.dupe(u8, txn_signature);
    defer allocator.free(tampered_signature);
    tampered_signature[tampered_signature.len - 1] = if (tampered_signature[tampered_signature.len - 1] == 'A') 'B' else 'A';
    try expectMismatch(tampered_signature, fixture.secp_signature);

    // Control B: tampered DER must be rejected by parser.
    const sig_bytes = try parseHexAlloc(allocator, txn_signature);
    defer allocator.free(sig_bytes);
    var tampered_der = try allocator.dupe(u8, sig_bytes);
    defer allocator.free(tampered_der);
    tampered_der[0] = 0x31; // invalid DER sequence tag; expected 0x30
    _ = secp256k1.parseDERSignature(tampered_der) catch |err| switch (err) {
        error.InvalidDERSignature,
        error.TruncatedSignature,
        error.SignatureTooShort,
        => return,
        else => return err,
    };
    return error.TamperedDERSignatureAccepted;
}

fn assertStrictSecpVectors(allocator: std.mem.Allocator) !void {
    const signing_domain_vectors = [_]SecpStrictVector{
        .{
            .name = "v1_uncompressed_sig72",
            .signing_prefix_hex = "53545800",
            .canonical_hex = "120000240000000168000000000000000a",
            .signing_hash_hex = "a4f2d3f63af8364de7341a0e22e5b4c3429ea09f82bed5c70284c6da43f0ee0f",
            .pubkey_hex = "048699404dcbc4fbf18381b4dd7a291038330d1b68a0f499a05615c3d1c4a4f103367afcb6b35377552b5c2c505ebb1da1ff3fdcfdf24115abe13dcbb5c8229398",
            .signature_hex = "3046022100eabd8871e5ec54cb2953bd03e8325921918d6d1cbb07b86c391f9ae63c8bb6d1022100cc621dae5186149b25f465e1c44d840404b11a94b789c6e0411a7f60386b282b",
        },
        .{
            .name = "v2_compressed_sig72",
            .signing_prefix_hex = "53545800",
            .canonical_hex = "1200006100000000000f4240",
            .signing_hash_hex = "60e5289f93110f248697c9ed6ce1df68c84276c4285400f9621bc29e06a6164f",
            .pubkey_hex = "0319c7dfcb8abd947d864dc6799741d32f6d2c7325472407ea0c373335732daf3a",
            .signature_hex = "3046022100cb4528d4f60cd9dd7ee395bc719f0468bb8fe2976c16b9ed0ec10d682b3ec7c6022100d02c6ceaee5f750c2d123bdb8f0803009ebde2a31312ac3d332eec7f8b084f93",
        },
        .{
            .name = "v3_compressed_sig71",
            .signing_prefix_hex = "53545800",
            .canonical_hex = "120000240000000155000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f68000000000000000a",
            .signing_hash_hex = "f9a93b3ec683df7f5111d3ae4311d3d7a13fb6678b1a3513f21e76297a32ac48",
            .pubkey_hex = "0249d90465c15548c5819079420bdc7409e0f9ae43b5150de87a452adea369a39c",
            .signature_hex = "3045022100af8126d584359ef6f7e35990478fac562a31651e2a35c9c478d56a22f33ea0fe02206181f8830026382efc74523f8fbea22d14507ae53457b2cd4ebc03ff5c97bd6a",
        },
    };

    const verify_vectors = [_]SecpVerifyVector{
        .{
            .name = "strict_verify_v1",
            .signing_hash_hex = "4a5cf8d6ee452e06633ebf65fb069a862885efce1a91718dfb26ffb49e0505c9",
            .pubkey_hex = "03f38e8c09c2b4446a5d72d8050e8a16f6398d4ed9debace3defeb59e4aa670d9e",
            .signature_hex = "30450221009381495b11ae66358704b255fc8fb4c32a326179aecde13a33a36916201b8faa02203da63c00a1d4ada3e0d1f178362572efd2640146a70e73d683ae8a5f876c72d8",
        },
        .{
            .name = "strict_verify_v2",
            .signing_hash_hex = "52fc53d5735a43a7eabeb56251ac2a6fa17f49e3fa160a23864f208e695d1249",
            .pubkey_hex = "0239fe749408e0e82a084d8764dbd00a0c5954b9d15cb70888ce1c9cd547c5ac17",
            .signature_hex = "3045022100be1288f1db489fbf09845db49947c18307771a1311852f762b8c48d8e088544c02207fd9b84ddae58afb018bf28bc95386097b9f214a540fb1dd3682dec2d736ff86",
        },
        .{
            .name = "strict_verify_v3",
            .signing_hash_hex = "6e842d6086c9edcd0da27eef13667cb1c838dd9d9c77b8364a5d36b5a069f2b4",
            .pubkey_hex = "02ecc3cc13c0ddd58ccd1c75e06d0c1ef1b8f153a3123c96db87a5ec752d4103ee",
            .signature_hex = "304402205c4933a114fbd4c9f2427182a529cd8f2f9584c293fa86b5218fcb6d9211b68f02203a4f9fc0576548a5819344192c994a7b69e2224daa457520b287dd0134828532",
        },
    };

    var first_hash: ?[32]u8 = null;
    var first_sig: ?[]u8 = null;
    var first_pub: ?[]u8 = null;
    var second_pub: ?[]u8 = null;
    defer if (first_sig) |s| allocator.free(s);
    defer if (first_pub) |p| allocator.free(p);
    defer if (second_pub) |p| allocator.free(p);

    for (signing_domain_vectors) |vec| {
        const canonical = try parseHexAlloc(allocator, vec.canonical_hex);
        defer allocator.free(canonical);
        const prefix = try parseHexAlloc(allocator, vec.signing_prefix_hex);
        defer allocator.free(prefix);
        if (prefix.len != 4) return error.InvalidSigningPrefixLength;

        const signing_blob = try allocator.alloc(u8, prefix.len + canonical.len);
        defer allocator.free(signing_blob);
        @memcpy(signing_blob[0..prefix.len], prefix);
        @memcpy(signing_blob[prefix.len..], canonical);
        const signing_hash = @import("crypto.zig").Hash.sha512Half(signing_blob);
        const expected_hash = try parseHex32(vec.signing_hash_hex);
        if (!std.mem.eql(u8, &signing_hash, &expected_hash)) return error.StrictSigningHashMismatch;

        // Signing-domain guardrails:
        // 1) signing hash must differ from canonical-body hash,
        // 2) signing hash must differ from wrong-prefix hash.
        const tx_body_hash = @import("crypto.zig").Hash.sha512Half(canonical);
        if (std.mem.eql(u8, &tx_body_hash, &signing_hash)) return error.SigningDomainConflatedWithBodyHash;

        var wrong_prefix_blob = try allocator.alloc(u8, 4 + canonical.len);
        defer allocator.free(wrong_prefix_blob);
        @memset(wrong_prefix_blob[0..4], 0);
        @memcpy(wrong_prefix_blob[4..], canonical);
        const wrong_prefix_hash = @import("crypto.zig").Hash.sha512Half(wrong_prefix_blob);
        if (std.mem.eql(u8, &wrong_prefix_hash, &signing_hash)) return error.SigningDomainConflatedWithWrongPrefix;

        std.debug.print("SIGNING_DOMAIN_CHECK {s} stx_ok=1 tx_hash_diff=1 wrong_prefix_diff=1\n", .{vec.name});

        const signature = try parseHexAlloc(allocator, vec.signature_hex);
        defer allocator.free(signature);
        _ = try secp256k1.parseDERSignature(signature);

        std.debug.print("CRYPTO_POSITIVE_VECTOR {s} hash_ok=1 sig_len={d}\n", .{ vec.name, signature.len });
    }

    if (!isStrictCryptoEnabled()) return;
    for (verify_vectors, 0..) |vec, idx| {
        const signing_hash = try parseHex32(vec.signing_hash_hex);
        const signature = try parseHexAlloc(allocator, vec.signature_hex);
        defer if (idx != 0) allocator.free(signature);
        const pubkey = try parseHexAlloc(allocator, vec.pubkey_hex);
        defer if (idx != 0 and idx != 1) allocator.free(pubkey);
        const ok = try secp256k1.verifySignature(pubkey, &signing_hash, signature);
        if (!ok) return error.StrictSecpVerifyFailed;

        if (idx == 0) {
            first_hash = signing_hash;
            first_sig = signature;
            first_pub = pubkey;
        } else if (idx == 1) {
            second_pub = pubkey;
        }
    }

    const base_hash = first_hash orelse return error.MissingStrictBaseVector;
    const base_sig = first_sig orelse return error.MissingStrictBaseVector;
    const base_pub = first_pub orelse return error.MissingStrictBaseVector;
    const other_pub = second_pub orelse return error.MissingStrictBaseVector;

    // Negative 1: tampered hash must fail verification.
    var bad_hash = base_hash;
    bad_hash[0] ^= 0x01;
    const bad_hash_ok = @import("crypto.zig").KeyPair.verify(base_pub, &bad_hash, base_sig, .secp256k1) catch false;
    if (bad_hash_ok) return error.TamperedHashAccepted;
    std.debug.print("CRYPTO_NEGATIVE_VECTOR tampered_hash verify_false=1\n", .{});

    // Negative 2: tampered signature must fail verification.
    var bad_sig = try allocator.dupe(u8, base_sig);
    defer allocator.free(bad_sig);
    bad_sig[bad_sig.len - 1] ^= 0x01;
    const bad_sig_ok = @import("crypto.zig").KeyPair.verify(base_pub, &base_hash, bad_sig, .secp256k1) catch false;
    if (bad_sig_ok) return error.TamperedSignatureAccepted;
    std.debug.print("CRYPTO_NEGATIVE_VECTOR tampered_rs verify_false=1\n", .{});

    // Negative 3: wrong pubkey for valid signature must fail verification.
    const wrong_pub_ok = @import("crypto.zig").KeyPair.verify(other_pub, &base_hash, base_sig, .secp256k1) catch false;
    if (wrong_pub_ok) return error.WrongPubKeyAccepted;
    std.debug.print("CRYPTO_NEGATIVE_VECTOR wrong_pubkey verify_false=1\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const fixture = Fixture{
        .server_build_version = "2.6.1-rc2",
        .server_state = "full",
        .server_peers = 90,
        .server_hash = "FB90529615FA52790E2B2E24C32A482DBF9F969C3FDC2726ED0A64A40962BF00",
        .server_seq = 11900686,
        .fee_status = "success",
        .fee_base = "10",
        .fee_median = "7500",
        .fee_minimum = "10",
        .fee_ledger_index = 11900687,
        .ledger_hash = "FB90529615FA52790E2B2E24C32A482DBF9F969C3FDC2726ED0A64A40962BF00",
        .ledger_index = 11900686,
        .ledger_account_hash = "A569ACFF4EB95A65B8FD3A9A7C0E68EE17A96EA051896A3F235863ED776ACBAE",
        .ledger_parent_hash = "630D7DDAFBCF0449FEC7E4EB4056F2187BDCC6C4315788D6416766A4B7C7F6B6",
        .ledger_transaction_hash = "FAA3C9DB987A612C9A4B011805F00BF69DA56E8DF127D9AACB7C13A1CD0BC505",
        .ledger_total_coins = "99999914350172385",
        .ledger_close_time = 815078240,
        .ledger_parent_close_time = 815078232,
        .ledger_close_time_resolution = 10,
        .ledger_close_flags = 0,
        .ledger_transactions_count = 6,
        .ledger_tx0_account = "rPickFLAKK7YkMwKvhSEN1yJAtfnB6qRJc",
        .ledger_tx0_type = "SignerListSet",
        .ledger_tx0_fee = "7500",
        .ledger_tx0_sequence = 11900682,
        .account_status = "error",
        .account_error_code = 35,
        .account_validated = true,
        .secp_tx_hash = "09D0D3C0AB0E6D8EBB3117C2FF1DD72F063818F528AF54A4553C8541DD2E8B5B",
        .secp_pub_key = "02D3FC6F04117E6420CAEA735C57CEEC934820BBCD109200933F6BBDD98F7BFBD9",
        .secp_signature = "3045022100E30FEACFAE9ED8034C4E24203BBFD6CE0D48ABCA901EDCE6EE04AA281A4DD73F02200CA7FDF03DC0B56F6E6FC5B499B4830F1ABD6A57FC4BE5C03F2CAF3CAFD1FF85",
        .secp_r = "E30FEACFAE9ED8034C4E24203BBFD6CE0D48ABCA901EDCE6EE04AA281A4DD73F",
        .secp_s = "0CA7FDF03DC0B56F6E6FC5B499B4830F1ABD6A57FC4BE5C03F2CAF3CAFD1FF85",
    };

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
        .balance = 123 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 7,
    });
    try state.putAccount(.{
        .account = destination,
        .balance = 3 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    });

    var methods = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);
    var rpc_server = rpc.RpcServer.init(allocator, 5005, &lm, &state, &processor);
    defer rpc_server.deinit();

    const account_info = try methods.accountInfo(account);
    defer allocator.free(account_info);
    try assertAccountInfoLocal(account_info, allocator);

    const server_info = try methods.serverInfo(1000);
    defer allocator.free(server_info);
    try assertServerInfoLocal(server_info, allocator);

    const fee = try methods.fee();
    defer allocator.free(fee);
    try assertFeeLocal(fee, allocator);
    const agent_status = try methods.agentStatus(1000);
    defer allocator.free(agent_status);
    const agent_config_get = try methods.agentConfigGet();
    defer allocator.free(agent_config_get);
    const submit_blob = try makeMinimalSubmitBlob(allocator, .payment, account, types.MIN_TX_FEE, 7, destination, 1 * types.XRP);
    defer allocator.free(submit_blob);
    const submit = try methods.submit(submit_blob);
    defer allocator.free(submit);
    const ping = try methods.ping();
    defer allocator.free(ping);
    const ledger_current = try methods.ledgerCurrent();
    defer allocator.free(ledger_current);

    const fixture_server = try std.fs.cwd().readFileAlloc(allocator, "test_data/server_info.json", 512 * 1024);
    defer allocator.free(fixture_server);
    const fixture_fee = try std.fs.cwd().readFileAlloc(allocator, "test_data/fee_info.json", 512 * 1024);
    defer allocator.free(fixture_fee);
    const fixture_acct = try std.fs.cwd().readFileAlloc(allocator, "test_data/account_info.json", 512 * 1024);
    defer allocator.free(fixture_acct);
    const fixture_ledger = try std.fs.cwd().readFileAlloc(allocator, "test_data/current_ledger.json", 2 * 1024 * 1024);
    defer allocator.free(fixture_ledger);
    const fixture_agent_schema = try std.fs.cwd().readFileAlloc(allocator, "test_data/agent_status_schema.json", 256 * 1024);
    defer allocator.free(fixture_agent_schema);
    const fixture_agent_config_schema = try std.fs.cwd().readFileAlloc(allocator, "test_data/agent_config_schema.json", 256 * 1024);
    defer allocator.free(fixture_agent_config_schema);
    const fixture_rpc_live_methods_schema = try std.fs.cwd().readFileAlloc(allocator, "test_data/rpc_live_methods_schema.json", 256 * 1024);
    defer allocator.free(fixture_rpc_live_methods_schema);
    const fixture_rpc_live_negative_schema = try std.fs.cwd().readFileAlloc(allocator, "test_data/rpc_live_negative_schema.json", 256 * 1024);
    defer allocator.free(fixture_rpc_live_negative_schema);

    try assertServerFixture(fixture_server, allocator, fixture);
    try assertFeeFixture(fixture_fee, allocator, fixture);
    try assertAccountFixture(fixture_acct, allocator, fixture);
    try assertLedgerFixture(fixture_ledger, allocator, fixture);
    try assertSecpFixture(fixture_ledger, allocator, fixture);
    try assertNegativeCryptoControls(fixture_ledger, allocator, fixture);
    try assertStrictSecpVectors(allocator);
    try assertAgentStatusSchema(agent_status, fixture_agent_schema, allocator);
    try assertAgentConfigGetSchema(agent_config_get, fixture_agent_config_schema, allocator);
    try assertRpcLiveMethodsContracts(account_info, submit, ping, ledger_current, fixture_rpc_live_methods_schema, allocator);
    try assertRpcLiveNegativeContracts(&rpc_server, fixture_rpc_live_negative_schema, allocator);
}
