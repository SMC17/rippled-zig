const std = @import("std");

/// XRP is the native currency of the XRP Ledger
/// Internally stored as "drops" where 1 XRP = 1,000,000 drops
pub const Drops = u64;

/// 1 XRP in drops
pub const XRP: Drops = 1_000_000;

/// Maximum XRP supply (100 billion XRP)
pub const MAX_XRP: Drops = 100_000_000_000 * XRP;

/// Minimum transaction fee (10 drops)
pub const MIN_TX_FEE: Drops = 10;

/// Maximum valid fee (1 XRP — anything above this is likely a mistake)
pub const MAX_TX_FEE: Drops = 1 * XRP;

/// Base reserve (10 XRP as of 2024)
pub const BASE_RESERVE: Drops = 10 * XRP;

/// Owner reserve per object (2 XRP as of 2024)
pub const OWNER_RESERVE: Drops = 2 * XRP;

/// Safe arithmetic for Drops — prevents overflow and enforces MAX_XRP invariant
pub const SafeDrops = struct {
    /// Add two Drops values, returning error on overflow or exceeding MAX_XRP
    pub fn add(a: Drops, b: Drops) error{DropsOverflow}!Drops {
        const result, const overflow = @addWithOverflow(a, b);
        if (overflow != 0) return error.DropsOverflow;
        if (result > MAX_XRP) return error.DropsOverflow;
        return result;
    }

    /// Subtract Drops, returning error on underflow
    pub fn sub(a: Drops, b: Drops) error{DropsUnderflow}!Drops {
        if (b > a) return error.DropsUnderflow;
        return a - b;
    }

    /// Validate a Drops value is within the valid range [0, MAX_XRP]
    pub fn validate(drops: Drops) error{DropsOverflow}!Drops {
        if (drops > MAX_XRP) return error.DropsOverflow;
        return drops;
    }

    /// Calculate account reserve: base_reserve + (owner_count * owner_reserve)
    pub fn accountReserve(owner_count: u32) error{DropsOverflow}!Drops {
        const owner_total = @as(u64, owner_count) * OWNER_RESERVE;
        return add(BASE_RESERVE, owner_total);
    }

    /// Check if an account can afford a fee (balance >= fee + reserve)
    pub fn canAfford(balance: Drops, fee: Drops, reserve: Drops) bool {
        const needed = add(fee, reserve) catch return false;
        return balance >= needed;
    }
};

/// Account address (20 bytes, displayed as base58 with checksum)
pub const AccountID = [20]u8;

/// Ledger sequence number
pub const LedgerSequence = u32;

/// Ledger hash (SHA-512 Half)
pub const LedgerHash = [32]u8;

/// Transaction hash
pub const TxHash = [32]u8;

/// Currency code (3-letter ISO 4217 or 160-bit hex)
pub const Currency = union(enum) {
    xrp: void,
    standard: [3]u8, // e.g., USD, EUR
    custom: [20]u8, // Custom currency code

    pub fn isXRP(self: Currency) bool {
        return self == .xrp;
    }
};

/// 160-bit (20-byte) encoded currency code for XRPL serialization.
///
/// Standard 3-char codes (e.g. "USD"): bytes 12-14 hold ASCII, rest are zero.
/// Hex currency codes: 40-char hex string decoded into all 20 bytes directly.
pub const CurrencyCode = struct {
    bytes: [20]u8,

    /// Encode a standard 3-character currency code (e.g. "USD").
    /// Places the three ASCII bytes at positions 12, 13, 14 with all other
    /// bytes zero, per XRPL serialization spec.
    pub fn fromStandard(code: []const u8) error{InvalidCurrencyCode}!CurrencyCode {
        if (code.len != 3) return error.InvalidCurrencyCode;
        // Validate ASCII: each byte must be printable ASCII (0x20-0x7E) and
        // the first byte must NOT be 0x00 (which would collide with XRP encoding).
        for (code) |ch| {
            if (ch < 0x20 or ch > 0x7E) return error.InvalidCurrencyCode;
        }
        var bytes = [_]u8{0} ** 20;
        bytes[12] = code[0];
        bytes[13] = code[1];
        bytes[14] = code[2];
        return CurrencyCode{ .bytes = bytes };
    }

    /// Decode a 40-character hex string into 20 raw bytes (hex / non-standard currency).
    pub fn fromHex(hex_str: []const u8) error{InvalidCurrencyCode}!CurrencyCode {
        if (hex_str.len != 40) return error.InvalidCurrencyCode;
        var bytes: [20]u8 = undefined;
        for (0..20) |i| {
            const hi = hexVal(hex_str[i * 2]) orelse return error.InvalidCurrencyCode;
            const lo = hexVal(hex_str[i * 2 + 1]) orelse return error.InvalidCurrencyCode;
            bytes[i] = (@as(u8, hi) << 4) | @as(u8, lo);
        }
        return CurrencyCode{ .bytes = bytes };
    }

    fn hexVal(c: u8) ?u4 {
        if (c >= '0' and c <= '9') return @intCast(c - '0');
        if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
        if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
        return null;
    }
};

/// IOU (token) amount for XRPL serialization.
///
/// Represents a non-XRP amount with mantissa, exponent, currency code, and issuer.
/// The mantissa is unsigned and `is_negative` tracks sign so that zero amounts
/// are never negative.
pub const IOUAmount = struct {
    /// Absolute mantissa.  For non-zero values this must be in [10^15, 10^16-1]
    /// after normalization.
    mantissa: u64,
    /// Decimal exponent (range: -96 .. +80 after normalization).
    exponent: i8,
    /// True when the amount is negative.
    is_negative: bool,
    /// Encoded 20-byte currency code.
    currency: CurrencyCode,
    /// Raw 20-byte issuer AccountID.
    issuer: AccountID,

    /// Create a zero IOU amount.
    pub fn zero(currency: CurrencyCode, issuer: AccountID) IOUAmount {
        return IOUAmount{
            .mantissa = 0,
            .exponent = 0,
            .is_negative = false,
            .currency = currency,
            .issuer = issuer,
        };
    }
};

/// Amount can be XRP (in drops) or IOU (issued currency)
pub const Amount = union(enum) {
    xrp: Drops,
    iou: struct {
        currency: Currency,
        value: i64, // Mantissa
        exponent: i8, // For decimal representation
        issuer: AccountID,
    },

    pub fn fromXRP(drops: Drops) Amount {
        return .{ .xrp = drops };
    }

    pub fn isXRP(self: Amount) bool {
        return self == .xrp;
    }
};

/// Transaction types supported by XRP Ledger
pub const TransactionType = enum(u16) {
    payment = 0,
    escrow_create = 1,
    escrow_finish = 2,
    account_set = 3,
    escrow_cancel = 4,
    regular_key_set = 5,
    offer_create = 7,
    offer_cancel = 8,
    ticket_create = 10,
    signer_list_set = 12,
    payment_channel_create = 13,
    payment_channel_fund = 14,
    payment_channel_claim = 15,
    check_create = 16,
    check_cash = 17,
    check_cancel = 18,
    deposit_preauth = 19,
    trust_set = 20,
    account_delete = 21,
    nftoken_mint = 25,
    nftoken_burn = 26,
    nftoken_create_offer = 27,
    nftoken_cancel_offer = 28,
    nftoken_accept_offer = 29,
    clawback = 30,
};

/// Transaction result codes
pub const TransactionResult = enum {
    success,
    tec_claim, // Fee claimed, but transaction failed
    tef_failure, // Failed, fee not claimed
    tel_local_error, // Local error
    tem_malformed, // Malformed transaction
    ter_retry, // Retry transaction
    tes_success, // Success
};

/// Signer for multi-signature transactions (BLOCKER #4 FIX)
pub const Signer = struct {
    account: AccountID,
    signing_pub_key: [33]u8,
    txn_signature: []const u8,
};

/// Base transaction structure
/// UPDATED: Now supports multi-signature (BLOCKER #4 FIX)
pub const Transaction = struct {
    tx_type: TransactionType,
    account: AccountID,
    fee: Drops,
    sequence: u32,
    account_txn_id: ?TxHash = null,
    last_ledger_sequence: ?LedgerSequence = null,

    // Single signature (traditional)
    signing_pub_key: ?[33]u8 = null, // Now optional for multi-sig
    txn_signature: ?[]const u8 = null,

    // Multi-signature support (BLOCKER #4 FIXED)
    signers: ?[]const Signer = null,

    // For multi-sig transactions:
    // - signing_pub_key is null or empty
    // - signers array contains multiple signatures
    // - Each signer has: account, signing_pub_key, txn_signature
};

/// Ledger entry types
pub const LedgerEntryType = enum(u16) {
    account_root = 0x61,
    ripple_state = 0x72,
    offer = 0x6f,
    directory_node = 0x64,
    amendments = 0x66,
    fee_settings = 0x73,
};

/// Account flags
pub const AccountFlags = packed struct {
    require_dest_tag: bool = false,
    require_auth: bool = false,
    disallow_xrp: bool = false,
    disable_master: bool = false,
    no_freeze: bool = false,
    global_freeze: bool = false,
    default_ripple: bool = false,
    deposit_auth: bool = false,
    _padding: u24 = 0,
};

/// Account root (the main account object in the ledger)
pub const AccountRoot = struct {
    account: AccountID,
    balance: Drops,
    flags: AccountFlags,
    owner_count: u32,
    previous_txn_id: TxHash,
    previous_txn_lgr_seq: LedgerSequence,
    sequence: u32,
    transfer_rate: ?u32 = null,
    email_hash: ?[16]u8 = null,
};

test "drops conversion" {
    try std.testing.expectEqual(@as(Drops, 1_000_000), XRP);
    try std.testing.expectEqual(@as(Drops, 100_000_000_000_000_000), MAX_XRP);
}

test "amount creation" {
    const amount = Amount.fromXRP(1000);
    try std.testing.expect(amount.isXRP());
}

test "currency types" {
    const xrp = Currency.xrp;
    try std.testing.expect(xrp == .xrp);

    const usd = Currency{ .standard = .{ 'U', 'S', 'D' } };
    try std.testing.expect(std.meta.activeTag(usd) == .standard);
}

test "CurrencyCode standard 3-char encoding" {
    const usd = try CurrencyCode.fromStandard("USD");
    // Bytes 0-11 must be zero
    for (0..12) |i| {
        try std.testing.expectEqual(@as(u8, 0), usd.bytes[i]);
    }
    try std.testing.expectEqual(@as(u8, 'U'), usd.bytes[12]);
    try std.testing.expectEqual(@as(u8, 'S'), usd.bytes[13]);
    try std.testing.expectEqual(@as(u8, 'D'), usd.bytes[14]);
    // Bytes 15-19 must be zero
    for (15..20) |i| {
        try std.testing.expectEqual(@as(u8, 0), usd.bytes[i]);
    }
}

test "CurrencyCode rejects invalid length" {
    try std.testing.expectError(error.InvalidCurrencyCode, CurrencyCode.fromStandard("US"));
    try std.testing.expectError(error.InvalidCurrencyCode, CurrencyCode.fromStandard("USDC"));
}

test "CurrencyCode hex encoding" {
    // 40-char hex: all 0x01 bytes
    const hex_code = try CurrencyCode.fromHex("0101010101010101010101010101010101010101");
    for (0..20) |i| {
        try std.testing.expectEqual(@as(u8, 0x01), hex_code.bytes[i]);
    }
}

test "CurrencyCode hex rejects invalid length" {
    try std.testing.expectError(error.InvalidCurrencyCode, CurrencyCode.fromHex("0102"));
}

test "IOUAmount zero" {
    const usd = try CurrencyCode.fromStandard("USD");
    const issuer = [_]u8{0} ** 20;
    const amt = IOUAmount.zero(usd, issuer);
    try std.testing.expectEqual(@as(u64, 0), amt.mantissa);
    try std.testing.expect(!amt.is_negative);
}

// ── SafeDrops tests ──

test "SafeDrops add normal" {
    const result = try SafeDrops.add(100, 200);
    try std.testing.expectEqual(@as(Drops, 300), result);
}

test "SafeDrops add overflow u64" {
    try std.testing.expectError(error.DropsOverflow, SafeDrops.add(std.math.maxInt(u64), 1));
}

test "SafeDrops add exceeds MAX_XRP" {
    try std.testing.expectError(error.DropsOverflow, SafeDrops.add(MAX_XRP, 1));
}

test "SafeDrops sub normal" {
    const result = try SafeDrops.sub(300, 100);
    try std.testing.expectEqual(@as(Drops, 200), result);
}

test "SafeDrops sub underflow" {
    try std.testing.expectError(error.DropsUnderflow, SafeDrops.sub(100, 200));
}

test "SafeDrops validate" {
    const valid = try SafeDrops.validate(1000 * XRP);
    try std.testing.expectEqual(@as(Drops, 1000 * XRP), valid);
    try std.testing.expectError(error.DropsOverflow, SafeDrops.validate(MAX_XRP + 1));
}

test "SafeDrops accountReserve" {
    // 0 objects: 10 XRP base
    const r0 = try SafeDrops.accountReserve(0);
    try std.testing.expectEqual(BASE_RESERVE, r0);
    // 5 objects: 10 + 5*2 = 20 XRP
    const r5 = try SafeDrops.accountReserve(5);
    try std.testing.expectEqual(@as(Drops, 20 * XRP), r5);
}

test "SafeDrops canAfford" {
    // 100 XRP balance, 12 drops fee, 10 XRP reserve -> can afford
    try std.testing.expect(SafeDrops.canAfford(100 * XRP, 12, 10 * XRP));
    // 10 XRP balance, 12 drops fee, 10 XRP reserve -> cannot afford
    try std.testing.expect(!SafeDrops.canAfford(10 * XRP, 12, 10 * XRP));
}
