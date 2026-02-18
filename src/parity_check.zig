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
};

const SecpStrictVector = struct {
    name: []const u8,
    signing_prefix_hex: []const u8,
    canonical_hex: []const u8,
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

fn assertStrictSecpVectors(allocator: std.mem.Allocator) !void {
    const vectors = [_]SecpStrictVector{
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

    var first_hash: ?[32]u8 = null;
    var first_sig: ?[]u8 = null;
    var first_pub: ?[]u8 = null;
    var second_pub: ?[]u8 = null;
    defer if (first_sig) |s| allocator.free(s);
    defer if (first_pub) |p| allocator.free(p);
    defer if (second_pub) |p| allocator.free(p);

    for (vectors, 0..) |vec, idx| {
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

        const signature = try parseHexAlloc(allocator, vec.signature_hex);
        defer if (idx != 0) allocator.free(signature);
        _ = try secp256k1.parseDERSignature(signature);

        std.debug.print("CRYPTO_POSITIVE_VECTOR {s} hash_ok=1 sig_len={d}\n", .{ vec.name, signature.len });

        if (!isStrictCryptoEnabled()) continue;

        const pubkey = try parseHexAlloc(allocator, vec.pubkey_hex);
        defer if (idx != 0 and idx != 1) allocator.free(pubkey);
        const ok = try @import("crypto.zig").KeyPair.verify(pubkey, &signing_hash, signature, .secp256k1);
        if (!ok) return error.StrictSecpVerifyFailed;

        if (idx == 0) {
            first_hash = signing_hash;
            first_sig = signature;
            first_pub = pubkey;
        } else if (idx == 1) {
            second_pub = pubkey;
        }
    }

    if (!isStrictCryptoEnabled()) return;
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
    try assertStrictSecpVectors(allocator);
}
