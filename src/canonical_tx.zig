const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const canonical = @import("canonical.zig");
const base58 = @import("base58.zig");

/// Canonical Transaction Serialization for XRPL
///
/// Serializes transactions in XRPL canonical binary format for signing
/// and hash computation. Supports the v1 transaction set:
///   - Payment (type 0)
///   - AccountSet (type 3)
///   - OfferCreate (type 7)
///   - OfferCancel (type 8)
pub const CanonicalTransactionSerializer = struct {
    allocator: std.mem.Allocator,
    serializer: canonical.CanonicalSerializer,

    pub fn init(allocator: std.mem.Allocator) !CanonicalTransactionSerializer {
        return CanonicalTransactionSerializer{
            .allocator = allocator,
            .serializer = try canonical.CanonicalSerializer.init(allocator),
        };
    }

    pub fn deinit(self: *CanonicalTransactionSerializer) void {
        self.serializer.deinit();
    }

    /// Serialize transaction for signing (EXCLUDES signature fields)
    pub fn serializeForSigning(self: *CanonicalTransactionSerializer, tx: TransactionJSON) ![]u8 {
        // Common fields (every transaction has these)

        // TransactionType (UInt16, field 2)
        if (tx.TransactionType) |tx_type| {
            try self.serializer.addUInt16(2, txTypeToCode(tx_type));
        }

        // Flags (UInt32, field 2)
        if (tx.Flags) |flags| {
            try self.serializer.addUInt32(2, flags);
        }

        // Sequence (UInt32, field 4)
        if (tx.Sequence) |seq| {
            try self.serializer.addUInt32(4, seq);
        }

        // DestinationTag (UInt32, field 14) — optional
        if (tx.DestinationTag) |tag| {
            try self.serializer.addUInt32(14, tag);
        }

        // LastLedgerSequence (UInt32, field 27)
        if (tx.LastLedgerSequence) |lls| {
            try self.serializer.addUInt32(27, lls);
        }

        // Fee (Amount, field 8) — always XRP drops
        if (tx.Fee) |fee_str| {
            const fee = try parseDrops(fee_str);
            try self.serializer.addXRPAmount(8, fee);
        }

        // Transaction-specific fields
        if (tx.TransactionType) |tx_type| {
            try self.addTransactionSpecificFields(tx_type, tx);
        }

        // Account (AccountID, field 1) — sender
        if (tx.Account) |account_str| {
            const account = try base58.Base58.decodeAccountID(self.allocator, account_str);
            try self.serializer.addAccountID(1, account);
        }

        // Destination (AccountID, field 3) — for Payment
        if (tx.Destination) |dest_str| {
            const dest = try base58.Base58.decodeAccountID(self.allocator, dest_str);
            try self.serializer.addAccountID(3, dest);
        }

        // NOTE: SigningPubKey and TxnSignature are EXCLUDED for signing hash

        return try self.serializer.finish();
    }

    /// Add transaction-type-specific fields
    fn addTransactionSpecificFields(self: *CanonicalTransactionSerializer, tx_type: []const u8, tx: TransactionJSON) !void {
        if (std.mem.eql(u8, tx_type, "Payment")) {
            // Amount (Amount, field 1) — payment amount
            if (tx.Amount) |amount_str| {
                const drops = try parseDrops(amount_str);
                try self.serializer.addXRPAmount(1, drops);
            }
            // SendMax (Amount, field 9) — optional
            if (tx.SendMax) |max_str| {
                const drops = try parseDrops(max_str);
                try self.serializer.addXRPAmount(9, drops);
            }
        } else if (std.mem.eql(u8, tx_type, "OfferCreate")) {
            // TakerPays (Amount, field 4)
            if (tx.TakerPays) |pays_str| {
                const drops = try parseDrops(pays_str);
                try self.serializer.addXRPAmount(4, drops);
            }
            // TakerGets (Amount, field 5)
            if (tx.TakerGets) |gets_str| {
                const drops = try parseDrops(gets_str);
                try self.serializer.addXRPAmount(5, drops);
            }
            // Expiration (UInt32, field 10) — optional
            if (tx.Expiration) |exp| {
                try self.serializer.addUInt32(10, exp);
            }
        } else if (std.mem.eql(u8, tx_type, "OfferCancel")) {
            // OfferSequence (UInt32, field 25)
            if (tx.OfferSequence) |seq| {
                try self.serializer.addUInt32(25, seq);
            }
        } else if (std.mem.eql(u8, tx_type, "AccountSet")) {
            // SetFlag (UInt32, field 18) — optional
            if (tx.SetFlag) |flag| {
                try self.serializer.addUInt32(18, flag);
            }
            // ClearFlag (UInt32, field 19) — optional
            if (tx.ClearFlag) |flag| {
                try self.serializer.addUInt32(19, flag);
            }
            // TransferRate (UInt32, field 11) — optional
            if (tx.TransferRate) |rate| {
                try self.serializer.addUInt32(11, rate);
            }
            // Domain (Blob, field 7) — optional
            if (tx.Domain) |domain| {
                try self.serializer.addBlob(7, domain);
            }
        }
    }

    /// Calculate body hash from serialized canonical data (SHA-512 Half)
    pub fn calculateBodyHash(serialized: []const u8) types.TxHash {
        return crypto.Hash.sha512Half(serialized);
    }

    /// Calculate XRPL signing hash (with signing prefix 0x53545800)
    pub fn calculateSigningHash(serialized: []const u8, allocator: std.mem.Allocator) !types.TxHash {
        return crypto.Hash.transactionSigningHash(serialized, allocator);
    }
};

/// Transaction JSON structure — covers the v1 supported set
pub const TransactionJSON = struct {
    // Common fields
    TransactionType: ?[]const u8 = null,
    Account: ?[]const u8 = null,
    Fee: ?[]const u8 = null,
    Sequence: ?u32 = null,
    Flags: ?u32 = null,
    LastLedgerSequence: ?u32 = null,
    DestinationTag: ?u32 = null,
    SigningPubKey: ?[]const u8 = null, // EXCLUDED from signing
    TxnSignature: ?[]const u8 = null, // EXCLUDED from signing
    hash: ?[]const u8 = null,

    // Payment fields
    Destination: ?[]const u8 = null,
    Amount: ?[]const u8 = null,
    SendMax: ?[]const u8 = null,

    // OfferCreate fields
    TakerPays: ?[]const u8 = null,
    TakerGets: ?[]const u8 = null,
    Expiration: ?u32 = null,

    // OfferCancel fields
    OfferSequence: ?u32 = null,

    // AccountSet fields
    SetFlag: ?u32 = null,
    ClearFlag: ?u32 = null,
    TransferRate: ?u32 = null,
    Domain: ?[]const u8 = null,

    // Legacy — kept for backward compat
    SignerQuorum: ?u32 = null,
    SignerEntries: ?[]const u8 = null,
};

/// XRPL transaction type codes
fn txTypeToCode(tx_type: []const u8) u16 {
    if (std.mem.eql(u8, tx_type, "Payment")) return 0;
    if (std.mem.eql(u8, tx_type, "EscrowCreate")) return 1;
    if (std.mem.eql(u8, tx_type, "EscrowFinish")) return 2;
    if (std.mem.eql(u8, tx_type, "AccountSet")) return 3;
    if (std.mem.eql(u8, tx_type, "EscrowCancel")) return 4;
    if (std.mem.eql(u8, tx_type, "SetRegularKey")) return 5;
    if (std.mem.eql(u8, tx_type, "NickNameSet")) return 6;
    if (std.mem.eql(u8, tx_type, "OfferCreate")) return 7;
    if (std.mem.eql(u8, tx_type, "OfferCancel")) return 8;
    if (std.mem.eql(u8, tx_type, "SignerListSet")) return 12;
    if (std.mem.eql(u8, tx_type, "PaymentChannelCreate")) return 13;
    if (std.mem.eql(u8, tx_type, "PaymentChannelFund")) return 14;
    if (std.mem.eql(u8, tx_type, "PaymentChannelClaim")) return 15;
    if (std.mem.eql(u8, tx_type, "CheckCreate")) return 16;
    if (std.mem.eql(u8, tx_type, "CheckCash")) return 17;
    if (std.mem.eql(u8, tx_type, "CheckCancel")) return 18;
    if (std.mem.eql(u8, tx_type, "TrustSet")) return 20;
    if (std.mem.eql(u8, tx_type, "NFTokenMint")) return 25;
    if (std.mem.eql(u8, tx_type, "NFTokenBurn")) return 26;
    if (std.mem.eql(u8, tx_type, "NFTokenCreateOffer")) return 27;
    if (std.mem.eql(u8, tx_type, "NFTokenCancelOffer")) return 28;
    if (std.mem.eql(u8, tx_type, "NFTokenAcceptOffer")) return 29;
    return 0; // Default to Payment
}

/// Parse drops string to u64
fn parseDrops(drops_str: []const u8) !u64 {
    return std.fmt.parseInt(u64, drops_str, 10);
}

// ── Tests ──

test "Payment transaction serialization" {
    const allocator = std.testing.allocator;

    var ser = try CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();

    const tx = TransactionJSON{
        .TransactionType = "Payment",
        .Sequence = 1,
        .Fee = "12",
        .Flags = 2147483648, // tfFullyCanonicalSig
    };

    const serialized = try ser.serializeForSigning(tx);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);

    // Verify field ordering: UInt16 (type 1) comes before UInt32 (type 2) comes before Amount (type 6)
    // First byte: TransactionType field header = (1 << 4) | 2 = 0x12
    try std.testing.expectEqual(@as(u8, 0x12), serialized[0]);

    const hash = CanonicalTransactionSerializer.calculateBodyHash(serialized);
    _ = hash;

    std.debug.print("[PASS] Payment transaction serialization with canonical ordering\n", .{});
    std.debug.print("   Serialized length: {d} bytes\n", .{serialized.len});
}

test "OfferCreate transaction serialization" {
    const allocator = std.testing.allocator;

    var ser = try CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();

    const tx = TransactionJSON{
        .TransactionType = "OfferCreate",
        .Sequence = 42,
        .Fee = "10",
        .TakerPays = "5000000",
        .TakerGets = "1000000",
    };

    const serialized = try ser.serializeForSigning(tx);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
    // TransactionType = 7 → field header (1 << 4) | 2 = 0x12, value = 0x0007
    try std.testing.expectEqual(@as(u8, 0x12), serialized[0]);
    try std.testing.expectEqual(@as(u8, 0x00), serialized[1]);
    try std.testing.expectEqual(@as(u8, 0x07), serialized[2]);

    std.debug.print("[PASS] OfferCreate transaction serialization\n", .{});
}

test "OfferCancel transaction serialization" {
    const allocator = std.testing.allocator;

    var ser = try CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();

    const tx = TransactionJSON{
        .TransactionType = "OfferCancel",
        .Sequence = 10,
        .Fee = "12",
        .OfferSequence = 7,
    };

    const serialized = try ser.serializeForSigning(tx);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
    std.debug.print("[PASS] OfferCancel transaction serialization\n", .{});
}

test "AccountSet transaction serialization" {
    const allocator = std.testing.allocator;

    var ser = try CanonicalTransactionSerializer.init(allocator);
    defer ser.deinit();

    const tx = TransactionJSON{
        .TransactionType = "AccountSet",
        .Sequence = 5,
        .Fee = "12",
        .SetFlag = 8, // asfDefaultRipple
    };

    const serialized = try ser.serializeForSigning(tx);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
    std.debug.print("[PASS] AccountSet transaction serialization\n", .{});
}

test "deterministic output for same inputs" {
    const allocator = std.testing.allocator;

    const tx = TransactionJSON{
        .TransactionType = "Payment",
        .Sequence = 100,
        .Fee = "12",
        .Flags = 2147483648,
    };

    var ser1 = try CanonicalTransactionSerializer.init(allocator);
    defer ser1.deinit();
    const out1 = try ser1.serializeForSigning(tx);
    defer allocator.free(out1);

    var ser2 = try CanonicalTransactionSerializer.init(allocator);
    defer ser2.deinit();
    const out2 = try ser2.serializeForSigning(tx);
    defer allocator.free(out2);

    try std.testing.expectEqualSlices(u8, out1, out2);
    std.debug.print("[PASS] Deterministic serialization output\n", .{});
}
