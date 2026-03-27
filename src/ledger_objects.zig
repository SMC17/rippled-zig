const std = @import("std");
const types = @import("types.zig");

const AccountID = types.AccountID;
const Drops = types.Drops;
const Amount = types.Amount;
const IOUAmount = types.IOUAmount;
const LedgerSequence = types.LedgerSequence;
const TxHash = types.TxHash;
const LedgerHash = types.LedgerHash;
const CurrencyCode = types.CurrencyCode;

/// Hash256 used for directory/index references.
pub const Hash256 = [32]u8;

// ---------------------------------------------------------------------------
// LedgerEntryType enum — canonical XRPL type codes
// ---------------------------------------------------------------------------

/// All major XRPL ledger entry types with their serialization type codes.
pub const LedgerEntryType = enum(u16) {
    account_root = 97, // 'a'
    amendments = 102, // 'f'
    check = 67, // 'C'
    deposit_preauth = 112, // 'p'
    directory_node = 100, // 'd'
    escrow = 117, // 'u'
    fee_settings = 115, // 's'
    ledger_hashes = 104, // 'h'
    negative_unl = 78, // 'N'
    nftoken_offer = 55,
    nftoken_page = 80, // 'P'
    offer = 111, // 'o'
    pay_channel = 120, // 'x'
    ripple_state = 114, // 'r'
    signer_list = 83, // 'S'
    ticket = 84, // 'T'
};

// ---------------------------------------------------------------------------
// AccountRoot flags
// ---------------------------------------------------------------------------

/// Bit-flags stored in the Flags field of an AccountRoot ledger object.
pub const AccountRootFlags = struct {
    pub const lsfPasswordSpent: u32 = 0x00010000;
    pub const lsfRequireDestTag: u32 = 0x00020000;
    pub const lsfRequireAuth: u32 = 0x00040000;
    pub const lsfDisallowXRP: u32 = 0x00080000;
    pub const lsfDisableMaster: u32 = 0x00100000;
    pub const lsfNoFreeze: u32 = 0x00200000;
    pub const lsfGlobalFreeze: u32 = 0x00400000;
    pub const lsfDefaultRipple: u32 = 0x00800000;
    pub const lsfDepositAuth: u32 = 0x01000000;
    pub const lsfAuthorizedNFTokenMinter: u32 = 0x02000000;

    pub fn hasFlag(flags: u32, flag: u32) bool {
        return (flags & flag) != 0;
    }
};

// ---------------------------------------------------------------------------
// AccountRoot
// ---------------------------------------------------------------------------

/// The primary account object stored in the XRPL ledger.
pub const AccountRoot = struct {
    account: AccountID,
    balance: Drops,
    flags: u32 = 0,
    owner_count: u32 = 0,
    previous_txn_id: TxHash = std.mem.zeroes(TxHash),
    previous_txn_lgr_seq: LedgerSequence = 0,
    sequence: u32 = 0,

    // Optional fields
    domain: ?[]const u8 = null,
    email_hash: ?[16]u8 = null,
    message_key: ?[]const u8 = null,
    transfer_rate: ?u32 = null,
    regular_key: ?AccountID = null,
    account_txn_id: ?TxHash = null,
    tick_size: ?u8 = null,
    nftoken_minter: ?AccountID = null,

    /// Check whether a specific AccountRootFlags bit is set.
    pub fn hasFlag(self: AccountRoot, flag: u32) bool {
        return AccountRootFlags.hasFlag(self.flags, flag);
    }

    /// Validate basic invariants.
    pub fn validate(self: AccountRoot) error{InvalidAccountRoot}!void {
        // Transfer rate, when set, must be 0 or >= 1000000000 (representing 1.0)
        if (self.transfer_rate) |rate| {
            if (rate != 0 and rate < 1_000_000_000) return error.InvalidAccountRoot;
            if (rate > 2_000_000_000) return error.InvalidAccountRoot;
        }
        // Tick size, when set, must be 3-15
        if (self.tick_size) |ts| {
            if (ts != 0 and (ts < 3 or ts > 15)) return error.InvalidAccountRoot;
        }
        return;
    }
};

// ---------------------------------------------------------------------------
// RippleState flags
// ---------------------------------------------------------------------------

/// Bit-flags for the RippleState (trust line) ledger object.
pub const RippleStateFlags = struct {
    pub const lsfLowReserve: u32 = 0x00010000;
    pub const lsfHighReserve: u32 = 0x00020000;
    pub const lsfLowAuth: u32 = 0x00040000;
    pub const lsfHighAuth: u32 = 0x00080000;
    pub const lsfLowNoRipple: u32 = 0x00100000;
    pub const lsfHighNoRipple: u32 = 0x00200000;
    pub const lsfLowFreeze: u32 = 0x00400000;
    pub const lsfHighFreeze: u32 = 0x00800000;

    pub fn hasFlag(flags: u32, flag: u32) bool {
        return (flags & flag) != 0;
    }
};

// ---------------------------------------------------------------------------
// RippleState (trust line)
// ---------------------------------------------------------------------------

/// A trust line between two accounts for a non-XRP currency.
pub const RippleState = struct {
    balance: IOUAmount,
    limit: IOUAmount,
    limit_peer: IOUAmount,
    flags: u32 = 0,
    low_node: u64 = 0,
    high_node: u64 = 0,
    previous_txn_id: TxHash = std.mem.zeroes(TxHash),
    previous_txn_lgr_seq: LedgerSequence = 0,
    low_quality_in: ?u32 = null,
    low_quality_out: ?u32 = null,
    high_quality_in: ?u32 = null,
    high_quality_out: ?u32 = null,

    pub fn hasFlag(self: RippleState, flag: u32) bool {
        return RippleStateFlags.hasFlag(self.flags, flag);
    }
};

// ---------------------------------------------------------------------------
// Offer (DEX order)
// ---------------------------------------------------------------------------

/// Offer flags.
pub const OfferFlags = struct {
    pub const lsfPassive: u32 = 0x00010000;
    pub const lsfSell: u32 = 0x00020000;

    pub fn hasFlag(flags: u32, flag: u32) bool {
        return (flags & flag) != 0;
    }
};

/// A standing DEX offer on the XRPL order book.
pub const Offer = struct {
    account: AccountID,
    sequence: u32,
    taker_pays: Amount,
    taker_gets: Amount,
    book_directory: Hash256 = std.mem.zeroes(Hash256),
    book_node: u64 = 0,
    owner_node: u64 = 0,
    flags: u32 = 0,
    expiration: ?u32 = null,
    previous_txn_id: TxHash = std.mem.zeroes(TxHash),
    previous_txn_lgr_seq: LedgerSequence = 0,

    pub fn hasFlag(self: Offer, flag: u32) bool {
        return OfferFlags.hasFlag(self.flags, flag);
    }

    /// Returns true when the offer has an expiration and it is at or before
    /// the given parent-close time.
    pub fn isExpired(self: Offer, parent_close_time: u32) bool {
        if (self.expiration) |exp| {
            return exp <= parent_close_time;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// DirectoryNode
// ---------------------------------------------------------------------------

/// Union payload distinguishing owner directories from order-book directories.
pub const DirectoryKind = union(enum) {
    owner: AccountID,
    order_book: struct {
        taker_pays_currency: CurrencyCode,
        taker_pays_issuer: AccountID,
        taker_gets_currency: CurrencyCode,
        taker_gets_issuer: AccountID,
    },
};

/// A page in a directory — either an owner directory or an offer-book directory.
pub const DirectoryNode = struct {
    root_index: Hash256,
    /// Entries (object IDs) contained in this directory page.
    indexes: []const Hash256 = &.{},
    index_next: ?u64 = null,
    index_previous: ?u64 = null,
    kind: DirectoryKind,
};

// ---------------------------------------------------------------------------
// Escrow
// ---------------------------------------------------------------------------

/// A held payment (escrow) on the XRPL.
pub const Escrow = struct {
    account: AccountID,
    destination: AccountID,
    amount: Drops,
    condition: ?[]const u8 = null,
    cancel_after: ?u32 = null,
    finish_after: ?u32 = null,
    source_tag: ?u32 = null,
    destination_tag: ?u32 = null,
    owner_node: u64 = 0,
    destination_node: u64 = 0,
    previous_txn_id: TxHash = std.mem.zeroes(TxHash),
    previous_txn_lgr_seq: LedgerSequence = 0,

    /// Validate that the escrow has at least one release mechanism.
    pub fn validate(self: Escrow) error{InvalidEscrow}!void {
        if (self.condition == null and self.finish_after == null and self.cancel_after == null) {
            return error.InvalidEscrow;
        }
        // cancel_after must be after finish_after when both are present
        if (self.cancel_after != null and self.finish_after != null) {
            if (self.cancel_after.? <= self.finish_after.?) return error.InvalidEscrow;
        }
        return;
    }
};

// ---------------------------------------------------------------------------
// PayChannel (payment channel)
// ---------------------------------------------------------------------------

/// A unidirectional XRP payment channel.
pub const PayChannel = struct {
    account: AccountID,
    destination: AccountID,
    amount: Drops,
    balance: Drops = 0,
    settle_delay: u32,
    public_key: [33]u8,
    expiration: ?u32 = null,
    cancel_after: ?u32 = null,
    source_tag: ?u32 = null,
    destination_tag: ?u32 = null,
    owner_node: u64 = 0,
    previous_txn_id: TxHash = std.mem.zeroes(TxHash),
    previous_txn_lgr_seq: LedgerSequence = 0,
};

// ---------------------------------------------------------------------------
// Check
// ---------------------------------------------------------------------------

/// A deferred payment (Check) that the destination can cash.
pub const Check = struct {
    account: AccountID,
    destination: AccountID,
    send_max: Amount,
    sequence: u32,
    expiration: ?u32 = null,
    invoice_id: ?Hash256 = null,
    source_tag: ?u32 = null,
    destination_tag: ?u32 = null,
    destination_node: u64 = 0,
    owner_node: u64 = 0,
    previous_txn_id: TxHash = std.mem.zeroes(TxHash),
    previous_txn_lgr_seq: LedgerSequence = 0,

    /// Returns true when the check has expired relative to the given close time.
    pub fn isExpired(self: Check, parent_close_time: u32) bool {
        if (self.expiration) |exp| {
            return exp <= parent_close_time;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// SignerList
// ---------------------------------------------------------------------------

/// A single entry in a SignerList.
pub const SignerEntry = struct {
    account: AccountID,
    weight: u16,
};

/// A list of weighted signers that can authorize multi-signed transactions.
pub const SignerList = struct {
    signer_quorum: u32,
    signer_entries: []const SignerEntry,
    owner_node: u64 = 0,
    previous_txn_id: TxHash = std.mem.zeroes(TxHash),
    previous_txn_lgr_seq: LedgerSequence = 0,

    /// Validate basic signer-list invariants.
    pub fn validate(self: SignerList) error{InvalidSignerList}!void {
        if (self.signer_entries.len == 0) return error.InvalidSignerList;
        if (self.signer_entries.len > 32) return error.InvalidSignerList;
        if (self.signer_quorum == 0) return error.InvalidSignerList;

        // Sum of weights must be >= quorum to be satisfiable.
        var total_weight: u32 = 0;
        for (self.signer_entries) |entry| {
            if (entry.weight == 0) return error.InvalidSignerList;
            total_weight += entry.weight;
        }
        if (total_weight < self.signer_quorum) return error.InvalidSignerList;
        return;
    }
};

// ---------------------------------------------------------------------------
// NFTokenPage
// ---------------------------------------------------------------------------

/// A single non-fungible token within an NFTokenPage.
pub const NFToken = struct {
    nftoken_id: Hash256,
    uri: ?[]const u8 = null,
};

/// A page in an account's NFToken collection.
pub const NFTokenPage = struct {
    previous_page_min: ?Hash256 = null,
    next_page_min: ?Hash256 = null,
    nftokens: []const NFToken = &.{},

    /// XRPL limits each NFTokenPage to 32 tokens.
    pub const MAX_TOKENS_PER_PAGE: usize = 32;

    /// Validate page constraints.
    pub fn validate(self: NFTokenPage) error{InvalidNFTokenPage}!void {
        if (self.nftokens.len > MAX_TOKENS_PER_PAGE) return error.InvalidNFTokenPage;
        return;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "LedgerEntryType enum values match XRPL type codes" {
    try std.testing.expectEqual(@as(u16, 97), @intFromEnum(LedgerEntryType.account_root));
    try std.testing.expectEqual(@as(u16, 102), @intFromEnum(LedgerEntryType.amendments));
    try std.testing.expectEqual(@as(u16, 67), @intFromEnum(LedgerEntryType.check));
    try std.testing.expectEqual(@as(u16, 112), @intFromEnum(LedgerEntryType.deposit_preauth));
    try std.testing.expectEqual(@as(u16, 100), @intFromEnum(LedgerEntryType.directory_node));
    try std.testing.expectEqual(@as(u16, 117), @intFromEnum(LedgerEntryType.escrow));
    try std.testing.expectEqual(@as(u16, 115), @intFromEnum(LedgerEntryType.fee_settings));
    try std.testing.expectEqual(@as(u16, 104), @intFromEnum(LedgerEntryType.ledger_hashes));
    try std.testing.expectEqual(@as(u16, 78), @intFromEnum(LedgerEntryType.negative_unl));
    try std.testing.expectEqual(@as(u16, 55), @intFromEnum(LedgerEntryType.nftoken_offer));
    try std.testing.expectEqual(@as(u16, 80), @intFromEnum(LedgerEntryType.nftoken_page));
    try std.testing.expectEqual(@as(u16, 111), @intFromEnum(LedgerEntryType.offer));
    try std.testing.expectEqual(@as(u16, 120), @intFromEnum(LedgerEntryType.pay_channel));
    try std.testing.expectEqual(@as(u16, 114), @intFromEnum(LedgerEntryType.ripple_state));
    try std.testing.expectEqual(@as(u16, 83), @intFromEnum(LedgerEntryType.signer_list));
    try std.testing.expectEqual(@as(u16, 84), @intFromEnum(LedgerEntryType.ticket));
}

test "AccountRoot construction and flag checking" {
    const acct = AccountRoot{
        .account = std.mem.zeroes(AccountID),
        .balance = 100 * types.XRP,
        .flags = AccountRootFlags.lsfDefaultRipple | AccountRootFlags.lsfDepositAuth,
        .sequence = 1,
    };
    try std.testing.expect(acct.hasFlag(AccountRootFlags.lsfDefaultRipple));
    try std.testing.expect(acct.hasFlag(AccountRootFlags.lsfDepositAuth));
    try std.testing.expect(!acct.hasFlag(AccountRootFlags.lsfDisableMaster));
}

test "AccountRoot validation" {
    // Valid account
    var acct = AccountRoot{
        .account = std.mem.zeroes(AccountID),
        .balance = 50 * types.XRP,
        .transfer_rate = 1_000_000_000,
    };
    try acct.validate();

    // Invalid transfer rate (too low)
    acct.transfer_rate = 500;
    try std.testing.expectError(error.InvalidAccountRoot, acct.validate());

    // Invalid transfer rate (too high)
    acct.transfer_rate = 2_500_000_000;
    try std.testing.expectError(error.InvalidAccountRoot, acct.validate());
}

test "RippleState construction and flags" {
    const usd = try CurrencyCode.fromStandard("USD");
    const issuer = std.mem.zeroes(AccountID);
    const zero_amt = IOUAmount.zero(usd, issuer);

    const trust_line = RippleState{
        .balance = zero_amt,
        .limit = zero_amt,
        .limit_peer = zero_amt,
        .flags = RippleStateFlags.lsfLowReserve | RippleStateFlags.lsfHighNoRipple,
    };
    try std.testing.expect(trust_line.hasFlag(RippleStateFlags.lsfLowReserve));
    try std.testing.expect(trust_line.hasFlag(RippleStateFlags.lsfHighNoRipple));
    try std.testing.expect(!trust_line.hasFlag(RippleStateFlags.lsfLowFreeze));
}

test "Offer construction and expiration" {
    const offer = Offer{
        .account = std.mem.zeroes(AccountID),
        .sequence = 42,
        .taker_pays = Amount.fromXRP(1000),
        .taker_gets = Amount.fromXRP(500),
        .flags = OfferFlags.lsfSell,
        .expiration = 750_000_000,
    };
    try std.testing.expect(offer.hasFlag(OfferFlags.lsfSell));
    try std.testing.expect(!offer.hasFlag(OfferFlags.lsfPassive));
    // Not expired before the expiration time
    try std.testing.expect(!offer.isExpired(749_999_999));
    // Expired at or after the expiration time
    try std.testing.expect(offer.isExpired(750_000_000));
    try std.testing.expect(offer.isExpired(750_000_001));
}

test "Offer without expiration never expires" {
    const offer = Offer{
        .account = std.mem.zeroes(AccountID),
        .sequence = 1,
        .taker_pays = Amount.fromXRP(100),
        .taker_gets = Amount.fromXRP(50),
    };
    try std.testing.expect(!offer.isExpired(999_999_999));
}

test "DirectoryNode owner directory" {
    const dir = DirectoryNode{
        .root_index = std.mem.zeroes(Hash256),
        .kind = .{ .owner = std.mem.zeroes(AccountID) },
    };
    try std.testing.expect(dir.kind == .owner);
    try std.testing.expect(dir.index_next == null);
    try std.testing.expect(dir.index_previous == null);
}

test "DirectoryNode order book directory" {
    const usd = try CurrencyCode.fromStandard("USD");
    const eur = try CurrencyCode.fromStandard("EUR");
    const issuer = std.mem.zeroes(AccountID);

    const dir = DirectoryNode{
        .root_index = std.mem.zeroes(Hash256),
        .kind = .{
            .order_book = .{
                .taker_pays_currency = usd,
                .taker_pays_issuer = issuer,
                .taker_gets_currency = eur,
                .taker_gets_issuer = issuer,
            },
        },
    };
    try std.testing.expect(dir.kind == .order_book);
}

test "Escrow validation" {
    // Valid escrow with finish_after
    var escrow = Escrow{
        .account = std.mem.zeroes(AccountID),
        .destination = std.mem.zeroes(AccountID),
        .amount = 10 * types.XRP,
        .finish_after = 700_000_000,
        .cancel_after = 800_000_000,
    };
    try escrow.validate();

    // Invalid: no release mechanism
    escrow.condition = null;
    escrow.finish_after = null;
    escrow.cancel_after = null;
    try std.testing.expectError(error.InvalidEscrow, escrow.validate());

    // Invalid: cancel_after <= finish_after
    escrow.finish_after = 800_000_000;
    escrow.cancel_after = 700_000_000;
    try std.testing.expectError(error.InvalidEscrow, escrow.validate());
}

test "PayChannel construction" {
    const channel = PayChannel{
        .account = std.mem.zeroes(AccountID),
        .destination = std.mem.zeroes(AccountID),
        .amount = 50 * types.XRP,
        .balance = 10 * types.XRP,
        .settle_delay = 3600,
        .public_key = std.mem.zeroes([33]u8),
        .expiration = 900_000_000,
    };
    try std.testing.expectEqual(@as(Drops, 50 * types.XRP), channel.amount);
    try std.testing.expectEqual(@as(Drops, 10 * types.XRP), channel.balance);
    try std.testing.expectEqual(@as(u32, 3600), channel.settle_delay);
}

test "Check construction and expiration" {
    const check = Check{
        .account = std.mem.zeroes(AccountID),
        .destination = std.mem.zeroes(AccountID),
        .send_max = Amount.fromXRP(1000),
        .sequence = 5,
        .expiration = 800_000_000,
    };
    try std.testing.expect(!check.isExpired(799_999_999));
    try std.testing.expect(check.isExpired(800_000_000));
}

test "SignerList validation" {
    const entries = [_]SignerEntry{
        .{ .account = std.mem.zeroes(AccountID), .weight = 1 },
        .{ .account = std.mem.zeroes(AccountID), .weight = 2 },
    };
    const signer_list = SignerList{
        .signer_quorum = 2,
        .signer_entries = &entries,
    };
    try signer_list.validate();

    // Invalid: quorum higher than total weight
    const bad_list = SignerList{
        .signer_quorum = 10,
        .signer_entries = &entries,
    };
    try std.testing.expectError(error.InvalidSignerList, bad_list.validate());

    // Invalid: zero quorum
    const zero_quorum = SignerList{
        .signer_quorum = 0,
        .signer_entries = &entries,
    };
    try std.testing.expectError(error.InvalidSignerList, zero_quorum.validate());

    // Invalid: empty entries
    const empty_list = SignerList{
        .signer_quorum = 1,
        .signer_entries = &.{},
    };
    try std.testing.expectError(error.InvalidSignerList, empty_list.validate());
}

test "SignerList rejects zero-weight entry" {
    const entries = [_]SignerEntry{
        .{ .account = std.mem.zeroes(AccountID), .weight = 0 },
    };
    const signer_list = SignerList{
        .signer_quorum = 1,
        .signer_entries = &entries,
    };
    try std.testing.expectError(error.InvalidSignerList, signer_list.validate());
}

test "NFTokenPage construction and validation" {
    const token_id = std.mem.zeroes(Hash256);
    const tokens = [_]NFToken{
        .{ .nftoken_id = token_id, .uri = "https://example.com/nft/1" },
        .{ .nftoken_id = token_id },
    };
    const page = NFTokenPage{
        .nftokens = &tokens,
    };
    try page.validate();
    try std.testing.expectEqual(@as(usize, 2), page.nftokens.len);
    try std.testing.expect(page.previous_page_min == null);
    try std.testing.expect(page.next_page_min == null);
}

test "NFTokenPage rejects oversized page" {
    // Build an array of 33 tokens (exceeds MAX_TOKENS_PER_PAGE = 32)
    var tokens: [33]NFToken = undefined;
    for (&tokens) |*t| {
        t.* = .{ .nftoken_id = std.mem.zeroes(Hash256) };
    }
    const page = NFTokenPage{
        .nftokens = &tokens,
    };
    try std.testing.expectError(error.InvalidNFTokenPage, page.validate());
}
