const std = @import("std");
const ledger = @import("ledger.zig");
const rpc_methods = @import("rpc_methods.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

const Fixture = struct {
    server_hash: []const u8,
    server_seq: i64,
    fee_base: []const u8,
    fee_median: []const u8,
    fee_ledger_index: i64,
    account_error_code: i64,
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

fn getBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.ExpectedBool,
    };
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
    if (!std.mem.eql(u8, status, "success")) return error.UnexpectedFixtureStatus;

    const base_fee = try getString(try getField(drops, "base_fee"));
    if (!std.mem.eql(u8, base_fee, fixture.fee_base)) return error.FeeFixtureBaseMismatch;

    const median_fee = try getString(try getField(drops, "median_fee"));
    if (!std.mem.eql(u8, median_fee, fixture.fee_median)) return error.FeeFixtureMedianMismatch;

    const ledger_index = try getInteger(try getField(result, "ledger_current_index"));
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
    if (!std.mem.eql(u8, status, "error")) return error.AccountFixtureExpectedError;

    const error_code = try getInteger(try getField(result, "error_code"));
    if (error_code != fixture.account_error_code) return error.AccountFixtureErrorCodeMismatch;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const fixture = Fixture{
        .server_hash = "FB90529615FA52790E2B2E24C32A482DBF9F969C3FDC2726ED0A64A40962BF00",
        .server_seq = 11900686,
        .fee_base = "10",
        .fee_median = "7500",
        .fee_ledger_index = 11900687,
        .account_error_code = 35,
    };

    var lm = try ledger.LedgerManager.init(allocator);
    defer lm.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    var processor = try transaction.TransactionProcessor.init(allocator);
    defer processor.deinit();

    const account = [_]u8{1} ** 20;
    try state.putAccount(.{
        .account = account,
        .balance = 123 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 7,
    });

    var rpc = rpc_methods.RpcMethods.init(allocator, &lm, &state, &processor);

    const account_info = try rpc.accountInfo(account);
    defer allocator.free(account_info);
    try assertAccountInfoLocal(account_info, allocator);

    const server_info = try rpc.serverInfo(1000);
    defer allocator.free(server_info);
    try assertServerInfoLocal(server_info, allocator);

    const fee = try rpc.fee();
    defer allocator.free(fee);
    try assertFeeLocal(fee, allocator);

    const fixture_server = try std.fs.cwd().readFileAlloc(allocator, "test_data/server_info.json", 512 * 1024);
    defer allocator.free(fixture_server);
    const fixture_fee = try std.fs.cwd().readFileAlloc(allocator, "test_data/fee_info.json", 512 * 1024);
    defer allocator.free(fixture_fee);
    const fixture_acct = try std.fs.cwd().readFileAlloc(allocator, "test_data/account_info.json", 512 * 1024);
    defer allocator.free(fixture_acct);

    try assertServerFixture(fixture_server, allocator, fixture);
    try assertFeeFixture(fixture_fee, allocator, fixture);
    try assertAccountFixture(fixture_acct, allocator, fixture);
}
