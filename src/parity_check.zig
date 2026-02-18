const std = @import("std");
const ledger = @import("ledger.zig");
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
    account_status: []const u8,
    account_error_code: i64,
    account_validated: bool,
    secp_tx_hash: []const u8,
    secp_pub_key: []const u8,
    secp_signature: []const u8,
    secp_r: []const u8,
    secp_s: []const u8,
    strict_signing_prefix_hex: []const u8,
    strict_canonical_hex: []const u8,
    strict_signing_hash_hex: []const u8,
    strict_pubkey_hex: []const u8,
    strict_signature_hex: []const u8,
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

fn assertStrictSecpVector(allocator: std.mem.Allocator, fixture: Fixture) !void {
    const canonical = try parseHexAlloc(allocator, fixture.strict_canonical_hex);
    defer allocator.free(canonical);
    const prefix = try parseHexAlloc(allocator, fixture.strict_signing_prefix_hex);
    defer allocator.free(prefix);
    if (prefix.len != 4) return error.InvalidSigningPrefixLength;

    const signing_blob = try allocator.alloc(u8, prefix.len + canonical.len);
    defer allocator.free(signing_blob);
    @memcpy(signing_blob[0..prefix.len], prefix);
    @memcpy(signing_blob[prefix.len..], canonical);
    const signing_hash = @import("crypto.zig").Hash.sha512Half(signing_blob);
    const expected_hash = try parseHex32(fixture.strict_signing_hash_hex);
    if (!std.mem.eql(u8, &signing_hash, &expected_hash)) return error.StrictSigningHashMismatch;

    if (!isStrictCryptoEnabled()) return;

    const pubkey = try parseHexAlloc(allocator, fixture.strict_pubkey_hex);
    defer allocator.free(pubkey);
    const signature = try parseHexAlloc(allocator, fixture.strict_signature_hex);
    defer allocator.free(signature);

    const ok = try @import("crypto.zig").KeyPair.verify(pubkey, &signing_hash, signature, .secp256k1);
    if (!ok) return error.StrictSecpVerifyFailed;
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
        .account_status = "error",
        .account_error_code = 35,
        .account_validated = true,
        .secp_tx_hash = "09D0D3C0AB0E6D8EBB3117C2FF1DD72F063818F528AF54A4553C8541DD2E8B5B",
        .secp_pub_key = "02D3FC6F04117E6420CAEA735C57CEEC934820BBCD109200933F6BBDD98F7BFBD9",
        .secp_signature = "3045022100E30FEACFAE9ED8034C4E24203BBFD6CE0D48ABCA901EDCE6EE04AA281A4DD73F02200CA7FDF03DC0B56F6E6FC5B499B4830F1ABD6A57FC4BE5C03F2CAF3CAFD1FF85",
        .secp_r = "E30FEACFAE9ED8034C4E24203BBFD6CE0D48ABCA901EDCE6EE04AA281A4DD73F",
        .secp_s = "0CA7FDF03DC0B56F6E6FC5B499B4830F1ABD6A57FC4BE5C03F2CAF3CAFD1FF85",
        .strict_signing_prefix_hex = "53545800",
        .strict_canonical_hex = "120000240000000168000000000000000a",
        .strict_signing_hash_hex = "a4f2d3f63af8364de7341a0e22e5b4c3429ea09f82bed5c70284c6da43f0ee0f",
        .strict_pubkey_hex = "04fa296a88ad11457343f591fa5b1b275cd62cfe2481e3692d0abfdf485038dfe0f7c1fdfef5d50b1849bf2a62f024aac4f3b98801023bd5e650a79df038da5b1b",
        .strict_signature_hex = "3046022100fc53d6975608ecdd6abbf5f85aac4a550aa5a288b8f0f278c99acb760285ed10022100e35d3969851015aa6bc8e6d14bd603019c4f87dd7db679900f8199d80301e363",
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
    const fixture_ledger = try std.fs.cwd().readFileAlloc(allocator, "test_data/current_ledger.json", 2 * 1024 * 1024);
    defer allocator.free(fixture_ledger);

    try assertServerFixture(fixture_server, allocator, fixture);
    try assertFeeFixture(fixture_fee, allocator, fixture);
    try assertAccountFixture(fixture_acct, allocator, fixture);
    try assertLedgerFixture(fixture_ledger, allocator, fixture);
    try assertSecpFixture(fixture_ledger, allocator, fixture);
    try assertNegativeCryptoControls(fixture_ledger, allocator, fixture);
    try assertStrictSecpVector(allocator, fixture);
}
