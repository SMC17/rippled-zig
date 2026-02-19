//! XRPL Peer Protocol Wire Format
//! Hand-written parser for Hello, Transaction, GetLedger, LedgerData, Proposal, Validation.
//! Compatible with length-prefixed binary framing. Real rippled uses XRPL/2.0 over HTTPS;
//! this module provides a minimal wire format for testing and standalone nodes.

const std = @import("std");
const types = @import("types.zig");

/// Message type codes (aligned with peer_protocol.zig)
pub const MsgType = enum(u8) {
    ping = 1,
    pong = 2,
    transaction = 3,
    get_ledger = 4,
    ledger_data = 5,
    proposal = 6,
    validation = 7,
};

/// Parsed Hello message
pub const Hello = struct {
    protocol_version: u32,
    network_id: u32,
    node_id: [32]u8,
    ledger_sequence: types.LedgerSequence,
    ledger_hash: types.LedgerHash,
    app_name: ?[]const u8 = null,

    pub fn parse(data: []const u8, allocator: std.mem.Allocator) !Hello {
        if (data.len < 76) return error.TooShort;
        var offset: usize = 0;

        const protocol_version = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        const network_id = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        var node_id: [32]u8 = undefined;
        @memcpy(&node_id, data[offset..][0..32]);
        offset += 32;

        const ledger_sequence = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        var ledger_hash: types.LedgerHash = undefined;
        @memcpy(&ledger_hash, data[offset..][0..32]);
        offset += 32;

        var app_name: ?[]const u8 = null;
        if (offset < data.len and data[offset] > 0 and data[offset] <= 64) {
            const len = data[offset];
            offset += 1;
            if (offset + len <= data.len) {
                app_name = try allocator.dupe(u8, data[offset..][0..len]);
            }
        }

        return Hello{
            .protocol_version = protocol_version,
            .network_id = network_id,
            .node_id = node_id,
            .ledger_sequence = ledger_sequence,
            .ledger_hash = ledger_hash,
            .app_name = app_name,
        };
    }

    pub fn deinit(self: *Hello, allocator: std.mem.Allocator) void {
        if (self.app_name) |name| {
            allocator.free(name);
            self.app_name = null;
        }
    }
};

/// Parsed GetLedger request
pub const GetLedger = struct {
    ledger_seq: types.LedgerSequence,
    ledger_hash: ?types.LedgerHash = null,

    pub fn parse(data: []const u8) !GetLedger {
        if (data.len < 5) return error.TooShort; // type(1) + seq(4)
        const ledger_seq = std.mem.readInt(u32, data[1..5], .big);
        var ledger_hash: ?types.LedgerHash = null;
        if (data.len >= 37) {
            var hash: types.LedgerHash = undefined;
            @memcpy(&hash, data[5..37]);
            ledger_hash = hash;
        }
        return GetLedger{
            .ledger_seq = ledger_seq,
            .ledger_hash = ledger_hash,
        };
    }
};

/// Parsed LedgerData response
pub const LedgerData = struct {
    sequence: types.LedgerSequence,
    hash: types.LedgerHash,
    parent_hash: types.LedgerHash,
    close_time: i64,

    pub fn parse(data: []const u8) !LedgerData {
        if (data.len < 77) return error.TooShort; // type(1) + seq(4) + hash(32) + parent(32) + close(8)
        var offset: usize = 1;
        const sequence = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        var hash: types.LedgerHash = undefined;
        @memcpy(&hash, data[offset..][0..32]);
        offset += 32;
        var parent_hash: types.LedgerHash = undefined;
        @memcpy(&parent_hash, data[offset..][0..32]);
        offset += 32;
        const close_time = std.mem.readInt(i64, data[offset..][0..8], .big);
        return LedgerData{
            .sequence = sequence,
            .hash = hash,
            .parent_hash = parent_hash,
            .close_time = close_time,
        };
    }
};

/// Parsed Proposal message (consensus round)
pub const Proposal = struct {
    validator_id: [32]u8,
    ledger_seq: types.LedgerSequence,
    close_time: i64,
    prior_ledger: types.LedgerHash,
    tx_hashes: []const types.TxHash,

    pub fn parse(data: []const u8, allocator: std.mem.Allocator) !Proposal {
        if (data.len < 77) return error.TooShort;
        var offset: usize = 1;
        var validator_id: [32]u8 = undefined;
        @memcpy(&validator_id, data[offset..][0..32]);
        offset += 32;
        const ledger_seq = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        const close_time = std.mem.readInt(i64, data[offset..][0..8], .big);
        offset += 8;
        var prior_ledger: types.LedgerHash = undefined;
        @memcpy(&prior_ledger, data[offset..][0..32]);
        offset += 32;

        var tx_hashes = std.ArrayList(types.TxHash).init(allocator);
        errdefer tx_hashes.deinit();
        while (offset + 32 <= data.len) {
            var h: types.TxHash = undefined;
            @memcpy(&h, data[offset..][0..32]);
            try tx_hashes.append(allocator, h);
            offset += 32;
        }
        return Proposal{
            .validator_id = validator_id,
            .ledger_seq = ledger_seq,
            .close_time = close_time,
            .prior_ledger = prior_ledger,
            .tx_hashes = try tx_hashes.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *Proposal, allocator: std.mem.Allocator) void {
        allocator.free(self.tx_hashes);
    }
};

/// Parsed Validation message
pub const Validation = struct {
    validator_id: [32]u8,
    ledger_seq: types.LedgerSequence,
    ledger_hash: types.LedgerHash,
    signature: [64]u8,

    pub fn parse(data: []const u8) !Validation {
        if (data.len < 137) return error.TooShort; // type(1) + validator(32) + seq(4) + hash(32) + sig(64)
        var offset: usize = 1;
        var validator_id: [32]u8 = undefined;
        @memcpy(&validator_id, data[offset..][0..32]);
        offset += 32;
        const ledger_seq = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        var ledger_hash: types.LedgerHash = undefined;
        @memcpy(&ledger_hash, data[offset..][0..32]);
        offset += 32;
        var signature: [64]u8 = undefined;
        @memcpy(&signature, data[offset..][0..64]);
        return Validation{
            .validator_id = validator_id,
            .ledger_seq = ledger_seq,
            .ledger_hash = ledger_hash,
            .signature = signature,
        };
    }
};

/// Serialize Hello for transmission
pub fn serializeHello(
    protocol_version: u32,
    network_id: u32,
    node_id: [32]u8,
    ledger_seq: types.LedgerSequence,
    ledger_hash: types.LedgerHash,
    app_name: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try list.writer().writeInt(u32, protocol_version, .big);
    try list.writer().writeInt(u32, network_id, .big);
    try list.appendSlice(&node_id);
    try list.writer().writeInt(u32, ledger_seq, .big);
    try list.appendSlice(&ledger_hash);
    try list.append(@intCast(app_name.len));
    try list.appendSlice(app_name);
    return list.toOwnedSlice();
}

/// Serialize GetLedger request
pub fn serializeGetLedger(ledger_seq: types.LedgerSequence, ledger_hash: ?*const types.LedgerHash, allocator: std.mem.Allocator) ![]u8 {
    const payload_len = 5 + if (ledger_hash != null) 32 else 0;
    var buf = try allocator.alloc(u8, payload_len);
    buf[0] = @intFromEnum(MsgType.get_ledger);
    std.mem.writeInt(u32, buf[1..5], ledger_seq, .big);
    if (ledger_hash) |h| {
        @memcpy(buf[5..37], h);
    }
    return buf;
}

/// Serialize LedgerData response
pub fn serializeLedgerData(ledger_data: LedgerData, allocator: std.mem.Allocator) ![]u8 {
    var buf = try allocator.alloc(u8, 77);
    buf[0] = @intFromEnum(MsgType.ledger_data);
    std.mem.writeInt(u32, buf[1..5], ledger_data.sequence, .big);
    @memcpy(buf[5..37], &ledger_data.hash);
    @memcpy(buf[37..69], &ledger_data.parent_hash);
    std.mem.writeInt(i64, buf[69..77], ledger_data.close_time, .big);
    return buf;
}

/// Serialize Transaction message (type byte + raw tx blob)
pub fn serializeTransaction(tx_blob: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buf = try allocator.alloc(u8, 1 + tx_blob.len);
    buf[0] = @intFromEnum(MsgType.transaction);
    @memcpy(buf[1..], tx_blob);
    return buf;
}

test "peer wire Hello parse round-trip" {
    const allocator = std.testing.allocator;
    const node_id = [_]u8{1} ** 32;
    const ledger_hash = [_]u8{2} ** 32;
    const serialized = try serializeHello(1, 1, node_id, 100, ledger_hash, "rippled-zig", allocator);
    defer allocator.free(serialized);

    var hello = try Hello.parse(serialized, allocator);
    defer hello.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), hello.protocol_version);
    try std.testing.expectEqual(@as(u32, 100), hello.ledger_sequence);
}

test "peer wire GetLedger parse" {
    var buf: [37]u8 = undefined;
    buf[0] = @intFromEnum(MsgType.get_ledger);
    std.mem.writeInt(u32, buf[1..5], 42, .big);
    @memcpy(buf[5..37], &([_]u8{0} ** 32));

    const gl = try GetLedger.parse(&buf);
    try std.testing.expectEqual(@as(types.LedgerSequence, 42), gl.ledger_seq);
}
