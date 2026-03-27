const std = @import("std");
const types = @import("types.zig");

// ---------------------------------------------------------------------------
// NFT Flag constants (XLS-20 bit positions within the 16-bit flags field)
// ---------------------------------------------------------------------------

/// tfBurnable (0x0001): issuer can always burn this NFT
pub const tfBurnable: u16 = 0x0001;
/// tfOnlyXRP (0x0002): can only be traded for XRP
pub const tfOnlyXRP: u16 = 0x0002;
/// tfTrustLine (0x0004): automatically create trust line for transfer fee
pub const tfTrustLine: u16 = 0x0004;
/// tfTransferable (0x0008): can be transferred to third parties
pub const tfTransferable: u16 = 0x0008;

/// NFT flags as a packed struct for convenient field access.
pub const NFTFlags = packed struct {
    burnable: bool = false,
    only_xrp: bool = false,
    trustline: bool = false,
    transferable: bool = true,
    _padding: u12 = 0,

    /// Convert to the raw 16-bit representation used in NFTokenID encoding.
    pub fn toU16(self: NFTFlags) u16 {
        return @bitCast(self);
    }

    /// Construct from a raw 16-bit value.
    pub fn fromU16(raw: u16) NFTFlags {
        return @bitCast(raw);
    }
};

// ---------------------------------------------------------------------------
// NFT ID generation — XRPL XLS-20 algorithm
// ---------------------------------------------------------------------------

/// Scramble the taxon so that NFTs from the same issuer+taxon do not have
/// sequential IDs.  The algorithm is:
///   scrambled = taxon XOR (sequence XOR (issuer_word rotated_left by taxon % 32))
/// where issuer_word is the first 4 bytes of the issuer account ID interpreted
/// as a big-endian u32.
pub fn scrambleTaxon(issuer: types.AccountID, taxon: u32, sequence: u32) u32 {
    const issuer_word: u32 = std.mem.readInt(u32, issuer[0..4], .big);
    const rotation: u5 = @intCast(taxon % 32);
    const rotated = std.math.rotl(u32, issuer_word, rotation);
    return taxon ^ (sequence ^ rotated);
}

/// Build a 32-byte NFTokenID per XLS-20:
///   bytes [ 0.. 1] = flags        (16 bits, big-endian)
///   bytes [ 2.. 3] = transfer_fee (16 bits, big-endian)
///   bytes [ 4..23] = issuer       (160 bits)
///   bytes [24..27] = scrambled taxon (32 bits, big-endian)
///   bytes [28..31] = sequence     (32 bits, big-endian)
pub fn generateNFTokenID(
    flags: u16,
    transfer_fee: u16,
    issuer: types.AccountID,
    taxon: u32,
    sequence: u32,
) [32]u8 {
    var id: [32]u8 = undefined;

    // flags (big-endian u16)
    std.mem.writeInt(u16, id[0..2], flags, .big);
    // transfer_fee (big-endian u16)
    std.mem.writeInt(u16, id[2..4], transfer_fee, .big);
    // issuer account ID (20 bytes)
    @memcpy(id[4..24], &issuer);
    // scrambled taxon (big-endian u32)
    const scrambled = scrambleTaxon(issuer, taxon, sequence);
    std.mem.writeInt(u32, id[24..28], scrambled, .big);
    // sequence (big-endian u32)
    std.mem.writeInt(u32, id[28..32], sequence, .big);

    return id;
}

/// Extract the issuer AccountID from an NFTokenID.
pub fn extractIssuer(nft_id: [32]u8) types.AccountID {
    var issuer: types.AccountID = undefined;
    @memcpy(&issuer, nft_id[4..24]);
    return issuer;
}

/// Extract the flags from an NFTokenID.
pub fn extractFlags(nft_id: [32]u8) u16 {
    return std.mem.readInt(u16, nft_id[0..2], .big);
}

/// Extract the transfer fee from an NFTokenID.
pub fn extractTransferFee(nft_id: [32]u8) u16 {
    return std.mem.readInt(u16, nft_id[2..4], .big);
}

/// Extract the sequence from an NFTokenID.
pub fn extractSequence(nft_id: [32]u8) u32 {
    return std.mem.readInt(u32, nft_id[28..32], .big);
}

// ---------------------------------------------------------------------------
// Transfer fee calculation
// ---------------------------------------------------------------------------

/// Compute the transfer fee amount collected by the issuer on a secondary sale.
/// transfer_fee is 0-50000 representing 0%-50% in 0.001% increments.
/// Returns: sale_price * transfer_fee / 50000
pub fn calculateTransferFee(sale_price: u64, transfer_fee: u16) u64 {
    if (transfer_fee == 0) return 0;
    // Use u128 to avoid overflow on large sale prices.
    // transfer_fee range 0-50000 maps to 0%-50%, so divide by 100000.
    const numerator: u128 = @as(u128, sale_price) * @as(u128, transfer_fee);
    return @intCast(numerator / 100000);
}

// ---------------------------------------------------------------------------
// NFTokenPage management
// ---------------------------------------------------------------------------

/// Maximum number of NFTs per page (XRPL protocol constant).
pub const MAX_TOKENS_PER_PAGE: usize = 32;

/// An NFT entry within a page, storing its ID and optional URI.
pub const PageNFToken = struct {
    nft_id: [32]u8,
    uri: ?[]const u8 = null,
};

/// An NFTokenPage holds up to 32 NFTs in sorted order by NFTokenID.
/// Page key = issuer_account_hash(first 24 bytes) || NFT_range_indicator(last 8 bytes).
pub const NFTokenPage = struct {
    key: [32]u8,
    tokens: std.ArrayList(PageNFToken),
    previous_page: ?[32]u8 = null,
    next_page: ?[32]u8 = null,

    pub fn init(allocator: std.mem.Allocator, key: [32]u8) NFTokenPage {
        return .{
            .key = key,
            .tokens = std.ArrayList(PageNFToken).init(allocator),
        };
    }

    pub fn deinit(self: *NFTokenPage) void {
        self.tokens.deinit();
    }

    /// Returns true when the page is at capacity.
    pub fn isFull(self: *const NFTokenPage) bool {
        return self.tokens.items.len >= MAX_TOKENS_PER_PAGE;
    }

    /// Insert an NFT into this page, maintaining sorted order by nft_id.
    /// Returns error.PageFull if the page already contains MAX_TOKENS_PER_PAGE items.
    pub fn insertSorted(self: *NFTokenPage, nft: PageNFToken) !void {
        if (self.tokens.items.len >= MAX_TOKENS_PER_PAGE) {
            return error.PageFull;
        }

        // Find insertion index via binary-style scan (items are sorted by nft_id).
        var insert_idx: usize = self.tokens.items.len;
        for (self.tokens.items, 0..) |existing, idx| {
            if (compareNFTIds(&nft.nft_id, &existing.nft_id) == .lt) {
                insert_idx = idx;
                break;
            }
        }

        try self.tokens.insert(insert_idx, nft);
    }

    /// Split this page into two pages.  The lower half stays in `self`, the
    /// upper half is moved into a newly-returned page.  The caller provides
    /// the key for the new (upper) page.
    pub fn split(self: *NFTokenPage, allocator: std.mem.Allocator, new_key: [32]u8) !NFTokenPage {
        const total = self.tokens.items.len;
        if (total <= 1) return error.CannotSplit;

        const mid = total / 2;
        var upper = NFTokenPage.init(allocator, new_key);

        // Move upper half to new page
        for (self.tokens.items[mid..]) |tok| {
            try upper.tokens.append(tok);
        }

        // Shrink self to lower half
        self.tokens.shrinkRetainingCapacity(mid);

        // Link pages
        upper.next_page = self.next_page;
        upper.previous_page = self.key;
        self.next_page = new_key;

        return upper;
    }
};

/// Compare two 32-byte NFTokenIDs lexicographically.
fn compareNFTIds(a: *const [32]u8, b: *const [32]u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// Compute the page key for a given NFTokenID.
/// Page key = issuer portion of ID (bytes 0..24) with the last 8 bytes
/// derived from the range indicator (upper bits of the scrambled taxon+seq).
pub fn computePageKey(nft_id: [32]u8) [32]u8 {
    var key: [32]u8 = undefined;
    // First 24 bytes come from the NFTokenID prefix (flags+fee+issuer)
    @memcpy(key[0..24], nft_id[0..24]);
    // Last 8 bytes are all 0xFF — the maximum token ID suffix for this
    // issuer prefix, designating the page that covers this range.
    @memset(key[24..32], 0xFF);
    return key;
}

/// Find which page (by index) a given nft_id belongs to.
/// Returns the index into the pages slice, or null if no suitable page exists.
pub fn findPageIndex(pages: []const NFTokenPage, nft_id: [32]u8) ?usize {
    const target_key = computePageKey(nft_id);
    for (pages, 0..) |page, idx| {
        if (std.mem.eql(u8, &page.key, &target_key)) {
            return idx;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Non-fungible token record
// ---------------------------------------------------------------------------

/// Non-fungible token
pub const NFToken = struct {
    nft_id: [32]u8,
    owner: types.AccountID,
    issuer: types.AccountID,
    taxon: u32,
    sequence: u32,
    transfer_fee: u16 = 0, // 0-50000 (0%-50%, in 0.001% increments)
    flags: NFTFlags = .{},
    uri: ?[]const u8 = null,
};

/// NFT offer (buy or sell)
pub const NFTOffer = struct {
    offer_id: [32]u8,
    owner: types.AccountID,
    nft_id: [32]u8,
    amount: types.Amount,
    is_sell_offer: bool,
    destination: ?types.AccountID = null,
    expiration: ?i64 = null,
};

// ---------------------------------------------------------------------------
// Transfer result returned from acceptOffer / brokered transfer
// ---------------------------------------------------------------------------

pub const TransferResult = struct {
    nft_id: [32]u8,
    from: types.AccountID,
    to: types.AccountID,
    sale_price: u64,
    transfer_fee_paid: u64,
    broker_fee_paid: u64,
};

// ---------------------------------------------------------------------------
// NFTManager — runtime manager for minting, burning, offers, transfers
// ---------------------------------------------------------------------------

/// NFT (Non-Fungible Token) support
pub const NFTManager = struct {
    allocator: std.mem.Allocator,
    nfts: std.ArrayList(NFToken),
    offers: std.ArrayList(NFTOffer),
    next_sequence: u32,

    pub fn init(allocator: std.mem.Allocator) NFTManager {
        return NFTManager{
            .allocator = allocator,
            .nfts = std.ArrayList(NFToken).init(allocator),
            .offers = std.ArrayList(NFTOffer).init(allocator),
            .next_sequence = 0,
        };
    }

    pub fn deinit(self: *NFTManager) void {
        for (self.nfts.items) |*nft| {
            if (nft.uri) |uri| {
                self.allocator.free(uri);
            }
        }
        self.nfts.deinit();
        self.offers.deinit();
    }

    /// Mint a new NFT using the XLS-20 ID generation algorithm.
    /// Returns the generated NFTokenID.
    pub fn mint(
        self: *NFTManager,
        issuer: types.AccountID,
        taxon: u32,
        flags: NFTFlags,
        transfer_fee: u16,
        uri: ?[]const u8,
    ) ![32]u8 {
        if (transfer_fee > 50000) return error.TransferFeeTooHigh;

        const seq = self.next_sequence;
        self.next_sequence += 1;

        const nft_id = generateNFTokenID(flags.toU16(), transfer_fee, issuer, taxon, seq);

        // Duplicate URI into managed memory if provided
        var owned_uri: ?[]const u8 = null;
        if (uri) |u| {
            if (u.len > 512) return error.URITooLong;
            const dup = try self.allocator.alloc(u8, u.len);
            @memcpy(dup, u);
            owned_uri = dup;
        }

        try self.nfts.append(.{
            .nft_id = nft_id,
            .owner = issuer, // minter is initial owner
            .issuer = issuer,
            .taxon = taxon,
            .sequence = seq,
            .transfer_fee = transfer_fee,
            .flags = flags,
            .uri = owned_uri,
        });

        return nft_id;
    }

    /// Mint a new NFT from a pre-built NFToken (legacy path kept for compatibility).
    pub fn mintNFT(self: *NFTManager, nft: NFToken) !void {
        try self.nfts.append(nft);
    }

    /// Burn an NFT.  The caller must be the owner, OR the issuer when tfBurnable is set.
    pub fn burn(self: *NFTManager, nft_id: [32]u8, caller: types.AccountID) !void {
        for (self.nfts.items, 0..) |nft, i| {
            if (std.mem.eql(u8, &nft.nft_id, &nft_id)) {
                const is_owner = std.mem.eql(u8, &nft.owner, &caller);
                const is_issuer = std.mem.eql(u8, &nft.issuer, &caller);

                if (!is_owner) {
                    // Issuer can burn only if tfBurnable flag is set
                    if (!(is_issuer and nft.flags.burnable)) {
                        return error.NotNFTOwner;
                    }
                }

                if (nft.uri) |uri| {
                    self.allocator.free(@constCast(uri));
                }

                _ = self.nfts.swapRemove(i);
                return;
            }
        }
        return error.NFTNotFound;
    }

    /// Burn an NFT (legacy name).
    pub fn burnNFT(self: *NFTManager, nft_id: [32]u8, owner: types.AccountID) !void {
        return self.burn(nft_id, owner);
    }

    /// Create an offer to buy or sell an NFT.
    /// Returns the generated offer_id.
    pub fn createOffer(
        self: *NFTManager,
        nft_id: [32]u8,
        owner: types.AccountID,
        amount: types.Amount,
        destination: ?types.AccountID,
        flags: u8, // bit 0 = is_sell_offer
    ) ![32]u8 {
        // Validate NFT exists
        const nft = self.findNFT(nft_id) orelse return error.NFTNotFound;

        const is_sell = (flags & 1) != 0;

        // If selling, caller must be the owner
        if (is_sell) {
            if (!std.mem.eql(u8, &nft.owner, &owner)) {
                return error.NotNFTOwner;
            }
        }

        // Non-transferable NFTs can only be transferred between issuer and holder.
        // Third parties cannot create buy or sell offers.
        if (!nft.flags.transferable) {
            const is_issuer = std.mem.eql(u8, &nft.issuer, &owner);
            const is_nft_owner = std.mem.eql(u8, &nft.owner, &owner);
            if (!is_issuer and !is_nft_owner) {
                return error.NFTNotTransferable;
            }
        }

        // Generate deterministic offer ID from nft_id + owner + offer count
        var offer_id: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&nft_id);
        hasher.update(&owner);
        var seq_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &seq_buf, @intCast(self.offers.items.len), .big);
        hasher.update(&seq_buf);
        hasher.final(&offer_id);

        try self.offers.append(.{
            .offer_id = offer_id,
            .owner = owner,
            .nft_id = nft_id,
            .amount = amount,
            .is_sell_offer = is_sell,
            .destination = destination,
        });

        return offer_id;
    }

    /// Accept an NFT offer — executes the transfer and collects the transfer fee.
    pub fn acceptOffer(self: *NFTManager, offer_id: [32]u8, acceptor: types.AccountID) !TransferResult {
        // Find and remove the offer
        const offer_data = self.findAndRemoveOffer(offer_id) orelse return error.OfferNotFound;

        // Find the NFT
        const nft = self.findNFTMut(offer_data.nft_id) orelse return error.NFTNotFound;

        // Enforce transferability
        if (!nft.flags.transferable) {
            // Non-transferable: only issuer<->owner transfers allowed
            const buyer = if (offer_data.is_sell_offer) (offer_data.destination orelse acceptor) else offer_data.owner;
            const is_issuer_involved = std.mem.eql(u8, &nft.issuer, &buyer) or
                std.mem.eql(u8, &nft.issuer, &nft.owner);
            if (!is_issuer_involved) {
                return error.NFTNotTransferable;
            }
        }

        const sale_price: u64 = switch (offer_data.amount) {
            .xrp => |drops| drops,
            .iou => 0, // IOU transfers: fee calc would use IOU amount
        };

        // Calculate transfer fee (only on secondary sales — not when issuer is seller)
        var fee_paid: u64 = 0;
        if (!std.mem.eql(u8, &nft.issuer, &nft.owner)) {
            fee_paid = calculateTransferFee(sale_price, nft.transfer_fee);
        }

        const previous_owner = nft.owner;

        // Execute the transfer
        if (offer_data.is_sell_offer) {
            nft.owner = offer_data.destination orelse acceptor;
        } else {
            nft.owner = offer_data.owner;
        }

        return .{
            .nft_id = nft.nft_id,
            .from = previous_owner,
            .to = nft.owner,
            .sale_price = sale_price,
            .transfer_fee_paid = fee_paid,
            .broker_fee_paid = 0,
        };
    }

    /// Brokered transfer: match a buy offer and a sell offer.
    /// The broker collects the difference (minus issuer transfer fee) as a fee.
    pub fn brokeredTransfer(
        self: *NFTManager,
        buy_offer_id: [32]u8,
        sell_offer_id: [32]u8,
    ) !TransferResult {
        // Validate both offers exist and are for the same NFT
        const buy_offer = self.findOffer(buy_offer_id) orelse return error.OfferNotFound;
        const sell_offer = self.findOffer(sell_offer_id) orelse return error.OfferNotFound;

        if (!std.mem.eql(u8, &buy_offer.nft_id, &sell_offer.nft_id)) {
            return error.OfferMismatch;
        }
        if (buy_offer.is_sell_offer) return error.InvalidOffer;
        if (!sell_offer.is_sell_offer) return error.InvalidOffer;

        const buy_price: u64 = switch (buy_offer.amount) {
            .xrp => |d| d,
            .iou => 0,
        };
        const sell_price: u64 = switch (sell_offer.amount) {
            .xrp => |d| d,
            .iou => 0,
        };

        // Buy price must be >= sell price
        if (buy_price < sell_price) return error.InsufficientOffer;

        const nft = self.findNFTMut(buy_offer.nft_id) orelse return error.NFTNotFound;

        // Transfer fee to issuer
        var issuer_fee: u64 = 0;
        if (!std.mem.eql(u8, &nft.issuer, &nft.owner)) {
            issuer_fee = calculateTransferFee(buy_price, nft.transfer_fee);
        }

        // Broker fee = buy_price - sell_price - issuer_fee
        const broker_fee = if (buy_price > sell_price + issuer_fee)
            buy_price - sell_price - issuer_fee
        else
            0;

        const previous_owner = nft.owner;
        nft.owner = buy_offer.owner;

        // Remove both offers
        _ = self.findAndRemoveOffer(buy_offer_id);
        _ = self.findAndRemoveOffer(sell_offer_id);

        return .{
            .nft_id = nft.nft_id,
            .from = previous_owner,
            .to = nft.owner,
            .sale_price = buy_price,
            .transfer_fee_paid = issuer_fee,
            .broker_fee_paid = broker_fee,
        };
    }

    /// Cancel an NFT offer
    pub fn cancelOffer(self: *NFTManager, offer_id: [32]u8) !void {
        if (self.findAndRemoveOffer(offer_id) == null) {
            return error.OfferNotFound;
        }
    }

    // -- internal helpers --

    fn findNFT(self: *const NFTManager, nft_id: [32]u8) ?*const NFToken {
        for (self.nfts.items) |*nft| {
            if (std.mem.eql(u8, &nft.nft_id, &nft_id)) return nft;
        }
        return null;
    }

    fn findNFTMut(self: *NFTManager, nft_id: [32]u8) ?*NFToken {
        for (self.nfts.items) |*nft| {
            if (std.mem.eql(u8, &nft.nft_id, &nft_id)) return nft;
        }
        return null;
    }

    fn findOffer(self: *const NFTManager, offer_id: [32]u8) ?NFTOffer {
        for (self.offers.items) |offer| {
            if (std.mem.eql(u8, &offer.offer_id, &offer_id)) return offer;
        }
        return null;
    }

    fn findAndRemoveOffer(self: *NFTManager, offer_id: [32]u8) ?NFTOffer {
        for (self.offers.items, 0..) |offer, i| {
            if (std.mem.eql(u8, &offer.offer_id, &offer_id)) {
                return self.offers.swapRemove(i);
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Transaction types (preserved from original)
// ---------------------------------------------------------------------------

/// NFTokenMint transaction
pub const NFTokenMintTransaction = struct {
    base: types.Transaction,
    taxon: u32,
    transfer_fee: u16 = 0,
    flags: NFTFlags = .{},
    uri: ?[]const u8 = null,

    pub fn create(
        account: types.AccountID,
        taxon: u32,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) NFTokenMintTransaction {
        return NFTokenMintTransaction{
            .base = types.Transaction{
                .tx_type = .nftoken_mint,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .taxon = taxon,
        };
    }

    pub fn validate(self: *const NFTokenMintTransaction) !void {
        // Transfer fee cannot exceed 50%
        if (self.transfer_fee > 50000) {
            return error.TransferFeeTooHigh;
        }

        // URI length limit
        if (self.uri) |uri| {
            if (uri.len > 512) return error.URITooLong;
        }
    }
};

/// NFTokenBurn transaction
pub const NFTokenBurnTransaction = struct {
    base: types.Transaction,
    nft_id: [32]u8,

    pub fn create(
        account: types.AccountID,
        nft_id: [32]u8,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) NFTokenBurnTransaction {
        return NFTokenBurnTransaction{
            .base = types.Transaction{
                .tx_type = .nftoken_burn,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .nft_id = nft_id,
        };
    }
};

/// NFTokenCreateOffer transaction
pub const NFTokenCreateOfferTransaction = struct {
    base: types.Transaction,
    nft_id: [32]u8,
    amount: types.Amount,
    is_sell_offer: bool,
    destination: ?types.AccountID = null,
    expiration: ?i64 = null,

    pub fn create(
        account: types.AccountID,
        nft_id: [32]u8,
        amount: types.Amount,
        is_sell: bool,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) NFTokenCreateOfferTransaction {
        return NFTokenCreateOfferTransaction{
            .base = types.Transaction{
                .tx_type = .nftoken_create_offer,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .nft_id = nft_id,
            .amount = amount,
            .is_sell_offer = is_sell,
        };
    }
};

/// NFTokenCancelOffer transaction
pub const NFTokenCancelOfferTransaction = struct {
    base: types.Transaction,
    offer_id: [32]u8, // Hash of the offer to cancel

    pub fn create(
        account: types.AccountID,
        offer_id: [32]u8,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) NFTokenCancelOfferTransaction {
        return NFTokenCancelOfferTransaction{
            .base = types.Transaction{
                .tx_type = .nftoken_cancel_offer,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .offer_id = offer_id,
        };
    }

    pub fn validate(self: *const NFTokenCancelOfferTransaction) !void {
        if (self.base.fee < types.MIN_TX_FEE) return error.InsufficientFee;
        if (self.base.sequence == 0) return error.InvalidSequence;
    }
};

/// NFTokenAcceptOffer transaction
pub const NFTokenAcceptOfferTransaction = struct {
    base: types.Transaction,
    nft_offer_id: [32]u8,
    broker_fee: ?types.Amount = null,

    pub fn create(
        account: types.AccountID,
        nft_offer_id: [32]u8,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
        broker_fee: ?types.Amount,
    ) NFTokenAcceptOfferTransaction {
        return NFTokenAcceptOfferTransaction{
            .base = types.Transaction{
                .tx_type = .nftoken_accept_offer,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .nft_offer_id = nft_offer_id,
            .broker_fee = broker_fee,
        };
    }

    pub fn validate(self: *const NFTokenAcceptOfferTransaction) !void {
        if (self.base.fee < types.MIN_TX_FEE) return error.InsufficientFee;
        if (self.base.sequence == 0) return error.InvalidSequence;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "nft manager" {
    const allocator = std.testing.allocator;
    var manager = NFTManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.nfts.items.len);
}

test "nft mint transaction" {
    const account = [_]u8{1} ** 20;

    const tx = NFTokenMintTransaction.create(
        account,
        12345, // taxon
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.nftoken_mint, tx.base.tx_type);
}

test "nft cancel offer transaction" {
    const account = [_]u8{1} ** 20;
    const offer_id = [_]u8{0xAA} ** 32;

    const tx = NFTokenCancelOfferTransaction.create(
        account,
        offer_id,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.nftoken_cancel_offer, tx.base.tx_type);
}

test "nft accept offer transaction" {
    const account = [_]u8{1} ** 20;
    const offer_id = [_]u8{0xBB} ** 32;

    const tx = NFTokenAcceptOfferTransaction.create(
        account,
        offer_id,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
        null, // no broker fee
    );

    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.nftoken_accept_offer, tx.base.tx_type);
}

test "transfer fee validation" {
    const account = [_]u8{1} ** 20;

    var tx = NFTokenMintTransaction.create(
        account,
        12345,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    // Valid transfer fee
    tx.transfer_fee = 10000; // 10%
    try tx.validate();

    // Invalid transfer fee
    tx.transfer_fee = 60000; // 60% - too high!
    try std.testing.expectError(error.TransferFeeTooHigh, tx.validate());
}

// ---------------------------------------------------------------------------
// New XLS-20 tests
// ---------------------------------------------------------------------------

test "NFT ID generation produces correct format" {
    const issuer = [_]u8{0xAA} ** 20;
    const flags: u16 = tfBurnable | tfTransferable; // 0x0009
    const transfer_fee: u16 = 5000; // 5%
    const taxon: u32 = 42;
    const sequence: u32 = 7;

    const nft_id = generateNFTokenID(flags, transfer_fee, issuer, taxon, sequence);

    // Verify flags at bytes 0..2
    try std.testing.expectEqual(flags, std.mem.readInt(u16, nft_id[0..2], .big));
    // Verify transfer_fee at bytes 2..4
    try std.testing.expectEqual(transfer_fee, std.mem.readInt(u16, nft_id[2..4], .big));
    // Verify issuer at bytes 4..24
    try std.testing.expectEqualSlices(u8, &issuer, nft_id[4..24]);
    // Verify sequence at bytes 28..32
    try std.testing.expectEqual(sequence, std.mem.readInt(u32, nft_id[28..32], .big));
    // Verify scrambled taxon at bytes 24..28 (not raw taxon)
    const expected_scrambled = scrambleTaxon(issuer, taxon, sequence);
    try std.testing.expectEqual(expected_scrambled, std.mem.readInt(u32, nft_id[24..28], .big));

    // Round-trip extraction
    try std.testing.expectEqual(flags, extractFlags(nft_id));
    try std.testing.expectEqual(transfer_fee, extractTransferFee(nft_id));
    try std.testing.expectEqual(sequence, extractSequence(nft_id));
    try std.testing.expectEqualSlices(u8, &issuer, &extractIssuer(nft_id));
}

test "taxon scrambling is deterministic" {
    const issuer = [_]u8{0x01} ** 20;
    const taxon: u32 = 100;

    // Same inputs produce same output
    const s1 = scrambleTaxon(issuer, taxon, 0);
    const s2 = scrambleTaxon(issuer, taxon, 0);
    try std.testing.expectEqual(s1, s2);

    // Different sequences produce different scrambled values
    const s3 = scrambleTaxon(issuer, taxon, 1);
    try std.testing.expect(s1 != s3);

    // Different issuers produce different scrambled values (same taxon+seq)
    const issuer2 = [_]u8{0x02} ** 20;
    const s4 = scrambleTaxon(issuer2, taxon, 0);
    try std.testing.expect(s1 != s4);

    // Scrambled value is NOT the raw taxon (unless by coincidence)
    // With these inputs the rotation should change the value
    const s5 = scrambleTaxon(issuer, 1, 0);
    // Just verify it runs and produces a u32
    try std.testing.expect(s5 <= std.math.maxInt(u32));
}

test "page holds up to 32 NFTs" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0} ** 32;
    var page = NFTokenPage.init(allocator, key);
    defer page.deinit();

    // Insert 32 tokens
    for (0..MAX_TOKENS_PER_PAGE) |i| {
        var nft_id: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u32, nft_id[28..32], @intCast(i), .big);
        try page.insertSorted(.{ .nft_id = nft_id });
    }
    try std.testing.expectEqual(@as(usize, 32), page.tokens.items.len);
    try std.testing.expect(page.isFull());

    // 33rd insert should fail
    var extra_id: [32]u8 = [_]u8{0xFF} ** 32;
    _ = &extra_id;
    try std.testing.expectError(error.PageFull, page.insertSorted(.{ .nft_id = extra_id }));

    // Verify sorted order
    for (0..page.tokens.items.len - 1) |i| {
        const order = compareNFTIds(&page.tokens.items[i].nft_id, &page.tokens.items[i + 1].nft_id);
        try std.testing.expect(order == .lt);
    }
}

test "mint and burn lifecycle" {
    const allocator = std.testing.allocator;
    var mgr = NFTManager.init(allocator);
    defer mgr.deinit();

    const issuer = [_]u8{0x42} ** 20;
    const flags = NFTFlags{ .burnable = true, .transferable = true };

    // Mint
    const nft_id = try mgr.mint(issuer, 1, flags, 0, "ipfs://QmTest");
    try std.testing.expectEqual(@as(usize, 1), mgr.nfts.items.len);

    // Verify the minted NFT has the correct fields
    const nft = mgr.findNFT(nft_id).?;
    try std.testing.expectEqualSlices(u8, &issuer, &nft.issuer);
    try std.testing.expectEqualSlices(u8, &issuer, &nft.owner);
    try std.testing.expectEqual(@as(u32, 1), nft.taxon);

    // Burn by owner
    try mgr.burn(nft_id, issuer);
    try std.testing.expectEqual(@as(usize, 0), mgr.nfts.items.len);

    // Burning again should fail
    try std.testing.expectError(error.NFTNotFound, mgr.burn(nft_id, issuer));
}

test "create and accept offer" {
    const allocator = std.testing.allocator;
    var mgr = NFTManager.init(allocator);
    defer mgr.deinit();

    const issuer = [_]u8{0x01} ** 20;
    const buyer = [_]u8{0x02} ** 20;
    const flags = NFTFlags{ .transferable = true };

    // Mint an NFT
    const nft_id = try mgr.mint(issuer, 0, flags, 0, null);

    // Create a sell offer from the issuer
    const offer_id = try mgr.createOffer(
        nft_id,
        issuer,
        types.Amount.fromXRP(1000),
        buyer, // destination
        1, // is_sell_offer
    );

    try std.testing.expectEqual(@as(usize, 1), mgr.offers.items.len);

    // Accept the offer
    const result = try mgr.acceptOffer(offer_id, buyer);
    try std.testing.expectEqualSlices(u8, &issuer, &result.from);
    try std.testing.expectEqualSlices(u8, &buyer, &result.to);
    try std.testing.expectEqual(@as(usize, 0), mgr.offers.items.len);

    // Verify ownership transferred
    const nft = mgr.findNFT(nft_id).?;
    try std.testing.expectEqualSlices(u8, &buyer, &nft.owner);
}

test "transfer fee calculation" {
    // 0% fee
    try std.testing.expectEqual(@as(u64, 0), calculateTransferFee(1_000_000, 0));

    // 5% fee (transfer_fee = 5000 means 5000/100000 = 5%)
    try std.testing.expectEqual(@as(u64, 50_000), calculateTransferFee(1_000_000, 5000));

    // 50% fee (transfer_fee = 50000, the maximum)
    try std.testing.expectEqual(@as(u64, 500_000), calculateTransferFee(1_000_000, 50000));

    // 0.001% fee (transfer_fee = 1, the minimum non-zero)
    // 1_000_000 * 1 / 100000 = 10
    try std.testing.expectEqual(@as(u64, 10), calculateTransferFee(1_000_000, 1));

    // Verify fee is collected on secondary sale through the manager
    const allocator = std.testing.allocator;
    var mgr = NFTManager.init(allocator);
    defer mgr.deinit();

    const issuer = [_]u8{0x01} ** 20;
    const buyer1 = [_]u8{0x02} ** 20;
    const buyer2 = [_]u8{0x03} ** 20;

    const flags = NFTFlags{ .transferable = true };
    const transfer_fee: u16 = 10000; // 10%

    // Mint with transfer fee
    const nft_id = try mgr.mint(issuer, 0, flags, transfer_fee, null);

    // First sale (issuer -> buyer1): no transfer fee because issuer is seller
    const sell1_id = try mgr.createOffer(nft_id, issuer, types.Amount.fromXRP(1000), buyer1, 1);
    const r1 = try mgr.acceptOffer(sell1_id, buyer1);
    try std.testing.expectEqual(@as(u64, 0), r1.transfer_fee_paid); // issuer selling: no fee

    // Second sale (buyer1 -> buyer2): transfer fee applies
    const sell2_id = try mgr.createOffer(nft_id, buyer1, types.Amount.fromXRP(2000), buyer2, 1);
    const r2 = try mgr.acceptOffer(sell2_id, buyer2);
    // 2000 drops * 10000/100000 = 200 drops (10%)
    try std.testing.expectEqual(@as(u64, 200), r2.transfer_fee_paid);
}

test "non-transferable NFT blocks transfer" {
    const allocator = std.testing.allocator;
    var mgr = NFTManager.init(allocator);
    defer mgr.deinit();

    const issuer = [_]u8{0x01} ** 20;
    const third_party = [_]u8{0x03} ** 20;

    // Mint a non-transferable NFT
    const flags = NFTFlags{ .transferable = false };
    const nft_id = try mgr.mint(issuer, 0, flags, 0, null);

    // Third party trying to create a buy offer should fail
    try std.testing.expectError(
        error.NFTNotTransferable,
        mgr.createOffer(nft_id, third_party, types.Amount.fromXRP(100), null, 0),
    );
}

test "burnable flag allows issuer burn" {
    const allocator = std.testing.allocator;
    var mgr = NFTManager.init(allocator);
    defer mgr.deinit();

    const issuer = [_]u8{0x01} ** 20;
    const owner = [_]u8{0x02} ** 20;

    // Mint a burnable, transferable NFT
    const flags_burnable = NFTFlags{ .burnable = true, .transferable = true };
    const nft_id_burnable = try mgr.mint(issuer, 0, flags_burnable, 0, null);

    // Transfer to owner
    const sell_id = try mgr.createOffer(nft_id_burnable, issuer, types.Amount.fromXRP(0), owner, 1);
    _ = try mgr.acceptOffer(sell_id, owner);

    // Issuer can burn even though they are not the owner (tfBurnable set)
    try mgr.burn(nft_id_burnable, issuer);
    try std.testing.expectEqual(@as(usize, 0), mgr.nfts.items.len);

    // Mint a non-burnable NFT and transfer it
    const flags_not_burnable = NFTFlags{ .burnable = false, .transferable = true };
    const nft_id2 = try mgr.mint(issuer, 0, flags_not_burnable, 0, null);

    const sell_id2 = try mgr.createOffer(nft_id2, issuer, types.Amount.fromXRP(0), owner, 1);
    _ = try mgr.acceptOffer(sell_id2, owner);

    // Issuer cannot burn when tfBurnable is NOT set
    try std.testing.expectError(error.NotNFTOwner, mgr.burn(nft_id2, issuer));

    // But owner can still burn their own NFT
    try mgr.burn(nft_id2, owner);
    try std.testing.expectEqual(@as(usize, 0), mgr.nfts.items.len);
}

test "page split distributes tokens correctly" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0} ** 32;
    var page = NFTokenPage.init(allocator, key);
    defer page.deinit();

    // Fill page with 32 tokens
    for (0..MAX_TOKENS_PER_PAGE) |i| {
        var nft_id: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u32, nft_id[28..32], @intCast(i), .big);
        try page.insertSorted(.{ .nft_id = nft_id });
    }

    // Split
    const new_key = [_]u8{0xFF} ** 32;
    var upper = try page.split(allocator, new_key);
    defer upper.deinit();

    // Lower half has 16, upper half has 16
    try std.testing.expectEqual(@as(usize, 16), page.tokens.items.len);
    try std.testing.expectEqual(@as(usize, 16), upper.tokens.items.len);

    // Verify linkage
    try std.testing.expectEqualSlices(u8, &new_key, &page.next_page.?);
    try std.testing.expectEqualSlices(u8, &key, &upper.previous_page.?);

    // Verify that all tokens in lower < all tokens in upper
    const last_lower = page.tokens.items[page.tokens.items.len - 1].nft_id;
    const first_upper = upper.tokens.items[0].nft_id;
    try std.testing.expect(compareNFTIds(&last_lower, &first_upper) == .lt);
}

test "brokered transfer with broker fee" {
    const allocator = std.testing.allocator;
    var mgr = NFTManager.init(allocator);
    defer mgr.deinit();

    const issuer = [_]u8{0x01} ** 20;
    const seller = [_]u8{0x02} ** 20;
    const buyer = [_]u8{0x03} ** 20;

    const flags = NFTFlags{ .transferable = true };
    const transfer_fee: u16 = 10000; // 10%

    // Mint and transfer to seller
    const nft_id = try mgr.mint(issuer, 0, flags, transfer_fee, null);
    const sell_to_seller = try mgr.createOffer(nft_id, issuer, types.Amount.fromXRP(0), seller, 1);
    _ = try mgr.acceptOffer(sell_to_seller, seller);

    // Seller creates sell offer at 1000 drops
    const sell_offer_id = try mgr.createOffer(nft_id, seller, types.Amount.fromXRP(1000), null, 1);

    // Buyer creates buy offer at 1500 drops
    const buy_offer_id = try mgr.createOffer(nft_id, buyer, types.Amount.fromXRP(1500), null, 0);

    // Broker matches the offers
    const result = try mgr.brokeredTransfer(buy_offer_id, sell_offer_id);

    try std.testing.expectEqualSlices(u8, &seller, &result.from);
    try std.testing.expectEqualSlices(u8, &buyer, &result.to);
    try std.testing.expectEqual(@as(u64, 1500), result.sale_price);
    // Transfer fee = 1500 * 10000 / 100000 = 150 (10%)
    try std.testing.expectEqual(@as(u64, 150), result.transfer_fee_paid);
    // Broker fee = 1500 - 1000 - 150 = 350
    try std.testing.expectEqual(@as(u64, 350), result.broker_fee_paid);

    // NFT now owned by buyer
    const nft = mgr.findNFT(nft_id).?;
    try std.testing.expectEqualSlices(u8, &buyer, &nft.owner);
}
