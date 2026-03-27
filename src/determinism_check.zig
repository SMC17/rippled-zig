const std = @import("std");
const crypto = @import("crypto.zig");
const canonical = @import("canonical.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

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

fn hashFixtureFile(path: []const u8, allocator: std.mem.Allocator) ![32]u8 {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(data);
    return crypto.Hash.sha512Half(data);
}

fn fillIncrementing(comptime N: usize) [N]u8 {
    var out: [N]u8 = undefined;
    for (&out, 0..) |*byte, i| byte.* = @intCast(i % 256);
    return out;
}

fn encodeHex32Lower(input: [32]u8) [64]u8 {
    const lut = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (input, 0..) |byte, i| {
        out[i * 2] = lut[byte >> 4];
        out[i * 2 + 1] = lut[byte & 0x0F];
    }
    return out;
}

fn recordVector(name: []const u8, hash: [32]u8) void {
    const hex = encodeHex32Lower(hash);
    std.debug.print("VECTOR_HASH {s} {s}\n", .{ name, hex });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const input = "xrpl-determinism-check";
    const h1 = crypto.Hash.sha512Half(input);
    const h2 = crypto.Hash.sha512Half(input);
    if (!std.mem.eql(u8, &h1, &h2)) return error.NonDeterministicHash;

    var a = try canonical.CanonicalSerializer.init(allocator);
    defer a.deinit();
    try a.addUInt64(8, 10);
    try a.addUInt16(2, 0);
    try a.addUInt32(4, 1);
    const out_a = try a.finish();
    defer allocator.free(out_a);

    var b = try canonical.CanonicalSerializer.init(allocator);
    defer b.deinit();
    try b.addUInt16(2, 0);
    try b.addUInt32(4, 1);
    try b.addUInt64(8, 10);
    const out_b = try b.finish();
    defer allocator.free(out_b);

    if (!std.mem.eql(u8, out_a, out_b)) return error.NonDeterministicCanonicalOrder;

    const expected_serialized_hex = "120000240000000168000000000000000a";
    const expected_serialized = try parseHexAlloc(allocator, expected_serialized_hex);
    defer allocator.free(expected_serialized);
    if (!std.mem.eql(u8, out_a, expected_serialized)) return error.CanonicalVectorMismatch;

    const serialized_hash = crypto.Hash.sha512Half(out_a);
    const expected_hash = try parseHex32("5de074b79ec3d36ebd7e704c214cdbf464b74d2e45794f5f7cd24832fb654c90");
    if (!std.mem.eql(u8, &serialized_hash, &expected_hash)) return error.CanonicalHashVectorMismatch;
    recordVector("canonical_u16_u32_u64", serialized_hash);

    // Additional canonical vector including AccountID field.
    const account_id = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05,
        0x06, 0x07, 0x08, 0x09, 0x0A,
        0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13, 0x14,
    };
    var c = try canonical.CanonicalSerializer.init(allocator);
    defer c.deinit();
    try c.addUInt16(2, 0);
    try c.addUInt32(4, 1);
    try c.addUInt64(8, 10);
    try c.addAccountID(1, account_id);
    const out_c = try c.finish();
    defer allocator.free(out_c);

    const expected_serialized_hex_2 = "120000240000000168000000000000000a810102030405060708090a0b0c0d0e0f1011121314";
    const expected_serialized_2 = try parseHexAlloc(allocator, expected_serialized_hex_2);
    defer allocator.free(expected_serialized_2);
    if (!std.mem.eql(u8, out_c, expected_serialized_2)) return error.CanonicalVector2Mismatch;

    const serialized_hash_2 = crypto.Hash.sha512Half(out_c);
    const expected_hash_2 = try parseHex32("09bd8a5ed82ddae1eeba4eb1a8ad4083ad59c6ece4b3e6443517eab7b85f6e2f");
    if (!std.mem.eql(u8, &serialized_hash_2, &expected_hash_2)) return error.CanonicalHashVector2Mismatch;
    recordVector("canonical_with_account", serialized_hash_2);

    // Fourth canonical vector: amount-like drops value encoded as UInt64 field.
    // Provenance: expected bytes + hash generated from deterministic encoded output.
    var amount_vec = try canonical.CanonicalSerializer.init(allocator);
    defer amount_vec.deinit();
    try amount_vec.addUInt16(2, 0);
    try amount_vec.addUInt64(1, 1_000_000); // 1 XRP in drops
    const out_amount = try amount_vec.finish();
    defer allocator.free(out_amount);
    const expected_amount_hex = "1200006100000000000f4240";
    const expected_amount = try parseHexAlloc(allocator, expected_amount_hex);
    defer allocator.free(expected_amount);
    if (!std.mem.eql(u8, out_amount, expected_amount)) return error.AmountVectorMismatch;
    const amount_hash = crypto.Hash.sha512Half(out_amount);
    const expected_amount_hash = try parseHex32("dab6b224b0a9b548231ce1e9a60f6be66a5a211f736f82daba7be401f9edb6d5");
    if (!std.mem.eql(u8, &amount_hash, &expected_amount_hash)) return error.AmountHashVectorMismatch;
    recordVector("amount_like_drops", amount_hash);

    // Fifth canonical vector: mixed field ordering with Hash256 + UInt fields.
    // Provenance: expected bytes + hash generated from deterministic encoded output.
    const hash256_payload = fillIncrementing(32);
    var mixed = try canonical.CanonicalSerializer.init(allocator);
    defer mixed.deinit();
    try mixed.addUInt64(8, 10);
    try mixed.addHash256(5, hash256_payload);
    try mixed.addUInt16(2, 0);
    try mixed.addUInt32(4, 1);
    const out_mixed = try mixed.finish();
    defer allocator.free(out_mixed);
    const expected_mixed_hex =
        "120000240000000155000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f68000000000000000a";
    const expected_mixed = try parseHexAlloc(allocator, expected_mixed_hex);
    defer allocator.free(expected_mixed);
    if (!std.mem.eql(u8, out_mixed, expected_mixed)) return error.MixedVectorMismatch;
    const mixed_hash = crypto.Hash.sha512Half(out_mixed);
    const expected_mixed_hash = try parseHex32("2482975f8c1f773e1aa0f45528df18834b0e08a1300105d668caedb8166f806f");
    if (!std.mem.eql(u8, &mixed_hash, &expected_mixed_hash)) return error.MixedHashVectorMismatch;
    recordVector("mixed_hash256_fields", mixed_hash);

    // Third canonical vector: VL boundary encoding at 192/193 bytes.
    const vl_192_payload = fillIncrementing(192);
    var vl_192 = try canonical.CanonicalSerializer.init(allocator);
    defer vl_192.deinit();
    try vl_192.addVL(3, &vl_192_payload);
    const out_vl_192 = try vl_192.finish();
    defer allocator.free(out_vl_192);
    if (out_vl_192.len != 194) return error.VL192UnexpectedLength;
    if (out_vl_192[0] != 0x73 or out_vl_192[1] != 0xC0) return error.VL192UnexpectedPrefix;
    if (!std.mem.eql(u8, out_vl_192[2..], &vl_192_payload)) return error.VL192PayloadMismatch;
    const out_vl_192_hash = crypto.Hash.sha512Half(out_vl_192);
    const expected_vl_192_hash = try parseHex32("2d12f8dafee6a41c108376601196fb2e30a20f2c566ddf7897cd34149906b19e");
    if (!std.mem.eql(u8, &out_vl_192_hash, &expected_vl_192_hash)) return error.VL192HashMismatch;
    recordVector("vl_192_boundary", out_vl_192_hash);

    const vl_193_payload = fillIncrementing(193);
    var vl_193 = try canonical.CanonicalSerializer.init(allocator);
    defer vl_193.deinit();
    try vl_193.addVL(3, &vl_193_payload);
    const out_vl_193 = try vl_193.finish();
    defer allocator.free(out_vl_193);
    if (out_vl_193.len != 196) return error.VL193UnexpectedLength;
    if (out_vl_193[0] != 0x73 or out_vl_193[1] != 0xC1 or out_vl_193[2] != 0x00) return error.VL193UnexpectedPrefix;
    if (!std.mem.eql(u8, out_vl_193[3..], &vl_193_payload)) return error.VL193PayloadMismatch;
    const out_vl_193_hash = crypto.Hash.sha512Half(out_vl_193);
    const expected_vl_193_hash = try parseHex32("31ac058dc1677933d75d3c1cb878a09db093a058e0262728366e93ba1b39111a");
    if (!std.mem.eql(u8, &out_vl_193_hash, &expected_vl_193_hash)) return error.VL193HashMismatch;
    recordVector("vl_193_boundary", out_vl_193_hash);

    // Sixth canonical vector: VL boundary encoding at 12480/12481 bytes.
    // Provenance: expected hashes computed from encoded bytes using SHA-512Half.
    const vl_12480_payload = fillIncrementing(12480);
    var vl_12480 = try canonical.CanonicalSerializer.init(allocator);
    defer vl_12480.deinit();
    try vl_12480.addVL(3, &vl_12480_payload);
    const out_vl_12480 = try vl_12480.finish();
    defer allocator.free(out_vl_12480);
    if (out_vl_12480.len != 12483) return error.VL12480UnexpectedLength;
    if (out_vl_12480[0] != 0x73 or out_vl_12480[1] != 0xF0 or out_vl_12480[2] != 0xFF) return error.VL12480UnexpectedPrefix;
    if (!std.mem.eql(u8, out_vl_12480[3..], &vl_12480_payload)) return error.VL12480PayloadMismatch;
    const out_vl_12480_hash = crypto.Hash.sha512Half(out_vl_12480);
    const expected_vl_12480_hash = try parseHex32("a96ff359d65cb919b763174f7f74b4bd0d9a8b4a2ecc6dbaf250b94da3dee051");
    if (!std.mem.eql(u8, &out_vl_12480_hash, &expected_vl_12480_hash)) return error.VL12480HashMismatch;
    recordVector("vl_12480_boundary", out_vl_12480_hash);

    const vl_12481_payload = fillIncrementing(12481);
    var vl_12481 = try canonical.CanonicalSerializer.init(allocator);
    defer vl_12481.deinit();
    try vl_12481.addVL(3, &vl_12481_payload);
    const out_vl_12481 = try vl_12481.finish();
    defer allocator.free(out_vl_12481);
    if (out_vl_12481.len != 12485) return error.VL12481UnexpectedLength;
    if (out_vl_12481[0] != 0x73 or out_vl_12481[1] != 0xF1 or out_vl_12481[2] != 0x00 or out_vl_12481[3] != 0x00) return error.VL12481UnexpectedPrefix;
    if (!std.mem.eql(u8, out_vl_12481[4..], &vl_12481_payload)) return error.VL12481PayloadMismatch;
    const out_vl_12481_hash = crypto.Hash.sha512Half(out_vl_12481);
    const expected_vl_12481_hash = try parseHex32("ef21ca47bc4b5bb1783515b38ec7bf7f5033f62edd7f4ad153092b91dbef886f");
    if (!std.mem.eql(u8, &out_vl_12481_hash, &expected_vl_12481_hash)) return error.VL12481HashMismatch;
    recordVector("vl_12481_boundary", out_vl_12481_hash);

    const fixtures = [_]struct { path: []const u8, expected_sha512_half_hex: []const u8 }{
        .{ .path = "test_data/current_ledger.json", .expected_sha512_half_hex = "e6fcf8db7b7f53f4cc854951603299702d142b32d776403f15b7e71e6db8c73c" },
        .{ .path = "test_data/server_info.json", .expected_sha512_half_hex = "217d7592a371f0efd670b95b16d1634841ed0a245d97f34386967ffa43c29236" },
        .{ .path = "test_data/fee_info.json", .expected_sha512_half_hex = "81f8d45439bd7766b58da374a9b67afbdfebf2b4ea96f24aca450dce4e5e429a" },
        .{ .path = "test_data/account_info.json", .expected_sha512_half_hex = "7622148fac1f791beb79dfed4d90c575887b75a604267abe6daf7c8f5eab893b" },
    };

    for (fixtures) |fixture| {
        const h = try hashFixtureFile(fixture.path, allocator);
        const expected = try parseHex32(fixture.expected_sha512_half_hex);
        if (!std.mem.eql(u8, &h, &expected)) return error.FixtureHashDrift;

        var all_zero = true;
        for (h) |byte| {
            if (byte != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return error.InvalidFixtureHash;
    }

    const amount = types.Amount.fromXRP(100 * types.XRP);
    if (!amount.isXRP()) return error.InvalidAmountModel;

    var payment = transaction.PaymentTransaction.create(
        [_]u8{0x01} ** 20,
        [_]u8{0x02} ** 20,
        types.Amount.fromXRP(100),
        10,
        1,
        [_]u8{0x03} ** 33,
    );
    payment.destination_tag = 7;
    const payment_bytes = try payment.serialize(allocator);
    defer allocator.free(payment_bytes);
    const expected_payment_hex =
        "12000024000000012e0000000761000000000000006468000000000000000a810101010101010101010101010101010101010101830202020202020202020202020202020202020202";
    const expected_payment = try parseHexAlloc(allocator, expected_payment_hex);
    defer allocator.free(expected_payment);
    if (!std.mem.eql(u8, payment_bytes, expected_payment)) return error.PaymentVectorMismatch;
    const payment_hash = crypto.Hash.sha512Half(payment_bytes);
    const expected_payment_hash = try parseHex32("9c16d342a2eb5e05c8016cb12a0dae566fd9e1edcb9ce2ecf91664a45c6da7ab");
    if (!std.mem.eql(u8, &payment_hash, &expected_payment_hash)) return error.PaymentHashVectorMismatch;
    recordVector("payment_tx_canonical", payment_hash);
    const payment_signing_hash = try crypto.Hash.transactionSigningHash(payment_bytes, allocator);
    const expected_payment_signing_hash = try parseHex32("5326bd2793a3a7f0d80a4b2f1f94b9febd629ae35b1114d211c376266e202fef");
    if (!std.mem.eql(u8, &payment_signing_hash, &expected_payment_signing_hash)) return error.PaymentSigningHashVectorMismatch;
    if (std.mem.eql(u8, &payment_signing_hash, &payment_hash)) return error.PaymentSigningHashMatchedBodyHash;
    recordVector("payment_tx_signing_hash", payment_signing_hash);

    var account_set = transaction.AccountSetTransaction.create(
        [_]u8{0x03} ** 20,
        10,
        2,
        [_]u8{0x04} ** 33,
    );
    account_set.set_flag = 2;
    account_set.clear_flag = 1;
    account_set.transfer_rate = 7;
    const account_set_bytes = try account_set.serialize(allocator);
    defer allocator.free(account_set_bytes);
    const expected_account_set_hex =
        "1200032400000002250000000226000000012b0000000768000000000000000a810303030303030303030303030303030303030303";
    const expected_account_set = try parseHexAlloc(allocator, expected_account_set_hex);
    defer allocator.free(expected_account_set);
    if (!std.mem.eql(u8, account_set_bytes, expected_account_set)) return error.AccountSetVectorMismatch;
    const account_set_hash = crypto.Hash.sha512Half(account_set_bytes);
    const expected_account_set_hash = try parseHex32("551c69f0dca814f154abb325a9e5e8bee7dd19b7fb1152e08d8dc580fef365a8");
    if (!std.mem.eql(u8, &account_set_hash, &expected_account_set_hash)) return error.AccountSetHashVectorMismatch;
    recordVector("account_set_tx_canonical", account_set_hash);
    const account_set_signing_hash = try crypto.Hash.transactionSigningHash(account_set_bytes, allocator);
    const expected_account_set_signing_hash = try parseHex32("b0fe8ab94c8f1388defcf5c122dfd9a2957a38de89d9ed211f5f63d4355cb2db");
    if (!std.mem.eql(u8, &account_set_signing_hash, &expected_account_set_signing_hash)) return error.AccountSetSigningHashVectorMismatch;
    if (std.mem.eql(u8, &account_set_signing_hash, &account_set_hash)) return error.AccountSetSigningHashMatchedBodyHash;
    recordVector("account_set_tx_signing_hash", account_set_signing_hash);

    var offer_create = transaction.OfferCreateTransaction.create(
        [_]u8{0x04} ** 20,
        types.Amount.fromXRP(200),
        types.Amount.fromXRP(300),
        10,
        3,
        [_]u8{0x05} ** 33,
    );
    offer_create.expiration = 9;
    const offer_create_bytes = try offer_create.serialize(allocator);
    defer allocator.free(offer_create_bytes);
    const expected_offer_create_hex =
        "12000724000000032a000000096100000000000000c862000000000000012c68000000000000000a810404040404040404040404040404040404040404";
    const expected_offer_create = try parseHexAlloc(allocator, expected_offer_create_hex);
    defer allocator.free(expected_offer_create);
    if (!std.mem.eql(u8, offer_create_bytes, expected_offer_create)) return error.OfferCreateVectorMismatch;
    const offer_create_hash = crypto.Hash.sha512Half(offer_create_bytes);
    const expected_offer_create_hash = try parseHex32("1e9aa27033d455015ac5c59bc0c780e889591904396793dbf5017397ae56431c");
    if (!std.mem.eql(u8, &offer_create_hash, &expected_offer_create_hash)) return error.OfferCreateHashVectorMismatch;
    recordVector("offer_create_tx_canonical", offer_create_hash);
    const offer_create_signing_hash = try crypto.Hash.transactionSigningHash(offer_create_bytes, allocator);
    const expected_offer_create_signing_hash = try parseHex32("ef7a1d8366cc16249a1048a543d83fd03ab3b4f6bdccdd33f799ffc65c72defe");
    if (!std.mem.eql(u8, &offer_create_signing_hash, &expected_offer_create_signing_hash)) return error.OfferCreateSigningHashVectorMismatch;
    if (std.mem.eql(u8, &offer_create_signing_hash, &offer_create_hash)) return error.OfferCreateSigningHashMatchedBodyHash;
    recordVector("offer_create_tx_signing_hash", offer_create_signing_hash);

    const offer_cancel = transaction.OfferCancelTransaction.create(
        [_]u8{0x05} ** 20,
        55,
        10,
        4,
        [_]u8{0x06} ** 33,
    );
    const offer_cancel_bytes = try offer_cancel.serialize(allocator);
    defer allocator.free(offer_cancel_bytes);
    const expected_offer_cancel_hex =
        "1200082400000004290000003768000000000000000a810505050505050505050505050505050505050505";
    const expected_offer_cancel = try parseHexAlloc(allocator, expected_offer_cancel_hex);
    defer allocator.free(expected_offer_cancel);
    if (!std.mem.eql(u8, offer_cancel_bytes, expected_offer_cancel)) return error.OfferCancelVectorMismatch;
    const offer_cancel_hash = crypto.Hash.sha512Half(offer_cancel_bytes);
    const expected_offer_cancel_hash = try parseHex32("6e16b9cb017fd43658b23b544cb5aa166a85597cb0e3c6f73270630d5254f2bc");
    if (!std.mem.eql(u8, &offer_cancel_hash, &expected_offer_cancel_hash)) return error.OfferCancelHashVectorMismatch;
    recordVector("offer_cancel_tx_canonical", offer_cancel_hash);
    const offer_cancel_signing_hash = try crypto.Hash.transactionSigningHash(offer_cancel_bytes, allocator);
    const expected_offer_cancel_signing_hash = try parseHex32("1ba4e5a81d9b7ec7c51b32e7a8bd5c0f21e5df1be895eef2e63df9f175bb664d");
    if (!std.mem.eql(u8, &offer_cancel_signing_hash, &expected_offer_cancel_signing_hash)) return error.OfferCancelSigningHashVectorMismatch;
    if (std.mem.eql(u8, &offer_cancel_signing_hash, &offer_cancel_hash)) return error.OfferCancelSigningHashMatchedBodyHash;
    recordVector("offer_cancel_tx_signing_hash", offer_cancel_signing_hash);

    const known_pubkey = [_]u8{
        0x02, 0xD3, 0xFC, 0x6F, 0x04, 0x11, 0x7E, 0x64, 0x20, 0xCA, 0xEA,
        0x73, 0x5C, 0x57, 0xCE, 0xEC, 0x93, 0x48, 0x20, 0xBB, 0xCD, 0x10,
        0x92, 0x00, 0x93, 0x3F, 0x6B, 0xBD, 0xD9, 0x8F, 0x7B, 0xFB, 0xD9,
    };
    const derived_account_id = crypto.Hash.accountID(&known_pubkey);
    const expected_account_id = [_]u8{
        0xfa, 0xb4, 0xff, 0x1b, 0xec, 0x2e, 0x13, 0x76, 0x13, 0xd2,
        0x6d, 0xeb, 0xf3, 0xd5, 0x7e, 0xbb, 0x9d, 0x2c, 0xed, 0xae,
    };
    if (!std.mem.eql(u8, &derived_account_id, &expected_account_id)) return error.AccountIDVectorMismatch;
    const account_id_hash = crypto.Hash.sha512Half(&derived_account_id);
    const expected_account_id_hash = try parseHex32("0b2519387da988c4ab65d432b6e6c7fb5cd413c89e8b7468da4743f81da6de22");
    if (!std.mem.eql(u8, &account_id_hash, &expected_account_id_hash)) return error.AccountIDHashVectorMismatch;
    recordVector("account_id_derivation", account_id_hash);

    const derived_address = try @import("base58.zig").Base58.encodeAccountID(allocator, derived_account_id);
    defer allocator.free(derived_address);
    if (!std.mem.eql(u8, derived_address, "rPickFLAKK7YkMwKvhSEN1yJAtfnB6qRJc")) return error.AccountAddressVectorMismatch;
    const address_hash = crypto.Hash.sha512Half(derived_address);
    const expected_address_hash = try parseHex32("e8768d07225f5a0e4793ad0a5bb2844064333413a09052ab5f0959f7e7712724");
    if (!std.mem.eql(u8, &address_hash, &expected_address_hash)) return error.AccountAddressHashVectorMismatch;
    recordVector("account_address_base58", address_hash);
}
