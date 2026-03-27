const std = @import("std");
const types = @import("types.zig");

/// XRPL Decentralized Identifiers (XLS-40)
///
/// DIDs on the XRP Ledger follow the W3C DID specification using the
/// did:xrpl method. Each account can set a DID document, URI, and data.
///
/// Transaction types:
///   DIDSet (type 49): Create or update a DID
///   DIDDelete (type 50): Remove a DID

pub const DID_SET_TX_TYPE: u16 = 49;
pub const DID_DELETE_TX_TYPE: u16 = 50;

/// Maximum sizes per XRPL spec
pub const MAX_DID_DOCUMENT_SIZE: usize = 256;
pub const MAX_DID_URI_SIZE: usize = 256;
pub const MAX_DID_DATA_SIZE: usize = 256;

/// DID document stored in ledger state
pub const DIDDocument = struct {
    account: types.AccountID,
    document: ?[]const u8 = null, // DID document (max 256 bytes)
    uri: ?[]const u8 = null, // URI pointing to off-ledger DID document
    data: ?[]const u8 = null, // Additional data (max 256 bytes)

    /// Validate DID document fields
    pub fn validate(self: DIDDocument) !void {
        if (self.document) |doc| {
            if (doc.len > MAX_DID_DOCUMENT_SIZE) return error.DocumentTooLarge;
        }
        if (self.uri) |u| {
            if (u.len > MAX_DID_URI_SIZE) return error.URITooLarge;
        }
        if (self.data) |d| {
            if (d.len > MAX_DID_DATA_SIZE) return error.DataTooLarge;
        }
        // At least one field must be set for DIDSet
        if (self.document == null and self.uri == null and self.data == null) {
            return error.EmptyDID;
        }
    }

    /// Format as a W3C DID string: did:xrpl:1:<account_hex>
    pub fn toDIDString(self: DIDDocument, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "did:xrpl:1:{s}", .{
            std.fmt.fmtSliceHexLower(&self.account),
        });
    }
};

/// DIDSet transaction
pub const DIDSetTx = struct {
    account: types.AccountID,
    fee: types.Drops,
    sequence: u32,
    document: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    data: ?[]const u8 = null,

    pub fn validate(self: DIDSetTx) !void {
        const doc = DIDDocument{
            .account = self.account,
            .document = self.document,
            .uri = self.uri,
            .data = self.data,
        };
        try doc.validate();
        if (self.fee < types.MIN_TX_FEE) return error.FeeTooLow;
    }
};

/// DIDDelete transaction — removes DID from the account
pub const DIDDeleteTx = struct {
    account: types.AccountID,
    fee: types.Drops,
    sequence: u32,

    pub fn validate(self: DIDDeleteTx) !void {
        if (self.fee < types.MIN_TX_FEE) return error.FeeTooLow;
    }
};

/// Parse a did:xrpl DID string to extract the account ID
pub fn parseDIDString(did_str: []const u8) !types.AccountID {
    // Format: did:xrpl:<network_id>:<account_hex>
    if (!std.mem.startsWith(u8, did_str, "did:xrpl:")) return error.InvalidDIDFormat;

    const after_prefix = did_str[9..]; // skip "did:xrpl:"
    // Find the account hex after the network id
    const colon_pos = std.mem.indexOf(u8, after_prefix, ":") orelse return error.InvalidDIDFormat;
    const account_hex = after_prefix[colon_pos + 1 ..];

    if (account_hex.len != 40) return error.InvalidAccountID;

    var account: types.AccountID = undefined;
    for (0..20) |i| {
        account[i] = std.fmt.parseInt(u8, account_hex[i * 2 .. i * 2 + 2], 16) catch
            return error.InvalidAccountID;
    }
    return account;
}

// ── Tests ──

test "DID document validation" {
    const account = [_]u8{0x01} ** 20;
    const valid = DIDDocument{
        .account = account,
        .document = "{\"id\":\"did:xrpl:1:...\"}",
        .uri = "https://example.com/did",
    };
    try valid.validate();
}

test "DID document rejects empty" {
    const account = [_]u8{0x01} ** 20;
    const empty = DIDDocument{ .account = account };
    try std.testing.expectError(error.EmptyDID, empty.validate());
}

test "DID document rejects oversized" {
    const account = [_]u8{0x01} ** 20;
    const too_big = DIDDocument{
        .account = account,
        .document = &([_]u8{'x'} ** 257),
    };
    try std.testing.expectError(error.DocumentTooLarge, too_big.validate());
}

test "DID string formatting" {
    const account = [_]u8{0x01} ** 20;
    const doc = DIDDocument{ .account = account, .uri = "https://example.com" };
    var buf: [128]u8 = undefined;
    const did_str = try doc.toDIDString(&buf);
    try std.testing.expect(std.mem.startsWith(u8, did_str, "did:xrpl:1:"));
}

test "DID string parsing" {
    const did_str = "did:xrpl:1:0101010101010101010101010101010101010101";
    const account = try parseDIDString(did_str);
    const expected = [_]u8{0x01} ** 20;
    try std.testing.expectEqualSlices(u8, &expected, &account);
}

test "DIDSet transaction validation" {
    const tx = DIDSetTx{
        .account = [_]u8{0x01} ** 20,
        .fee = 12,
        .sequence = 1,
        .uri = "https://example.com/did",
    };
    try tx.validate();
}

test "DIDDelete transaction validation" {
    const tx = DIDDeleteTx{
        .account = [_]u8{0x01} ** 20,
        .fee = 12,
        .sequence = 1,
    };
    try tx.validate();
}
