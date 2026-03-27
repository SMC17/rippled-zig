const std = @import("std");
const types = @import("types.zig");

/// NFT (Non-Fungible Token) support
pub const NFTManager = struct {
    allocator: std.mem.Allocator,
    nfts: std.ArrayList(NFToken),
    offers: std.ArrayList(NFTOffer),

    pub fn init(allocator: std.mem.Allocator) NFTManager {
        return NFTManager{
            .allocator = allocator,
            .nfts = std.ArrayList(NFToken).initCapacity(allocator, 0) catch unreachable,
            .offers = std.ArrayList(NFTOffer).initCapacity(allocator, 0) catch unreachable,
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

    /// Mint a new NFT
    pub fn mintNFT(self: *NFTManager, nft: NFToken) !void {
        // Generate NFT ID from issuer + sequence + taxon
        // TODO: Use proper NFT ID algorithm

        try self.nfts.append(nft);
    }

    /// Burn an NFT
    pub fn burnNFT(self: *NFTManager, nft_id: [32]u8, owner: types.AccountID) !void {
        for (self.nfts.items, 0..) |nft, i| {
            if (std.mem.eql(u8, &nft.nft_id, &nft_id)) {
                if (!std.mem.eql(u8, &nft.owner, &owner)) {
                    return error.NotNFTOwner;
                }

                if (nft.uri) |uri| {
                    self.allocator.free(uri);
                }

                _ = self.nfts.swapRemove(i);
                return;
            }
        }
        return error.NFTNotFound;
    }

    /// Create an NFT offer
    pub fn createOffer(self: *NFTManager, offer: NFTOffer) !void {
        // Validate NFT exists
        var nft_exists = false;
        for (self.nfts.items) |nft| {
            if (std.mem.eql(u8, &nft.nft_id, &offer.nft_id)) {
                nft_exists = true;
                break;
            }
        }

        if (!nft_exists) return error.NFTNotFound;

        try self.offers.append(offer);
    }

    /// Cancel an NFT offer - WEEK 3 DAY 19
    pub fn cancelOffer(self: *NFTManager, offer_id: [32]u8) !void {
        for (self.offers.items, 0..) |offer, idx| {
            if (std.mem.eql(u8, &offer.offer_id, &offer_id)) {
                _ = self.offers.swapRemove(idx);
                return;
            }
        }
        return error.OfferNotFound;
    }

    /// Accept an NFT offer
    pub fn acceptOffer(self: *NFTManager, offer_id: [32]u8) !void {
        for (self.offers.items, 0..) |offer, i| {
            if (std.mem.eql(u8, &offer.offer_id, &offer_id)) {
                // Transfer NFT ownership
                for (self.nfts.items) |*nft| {
                    if (std.mem.eql(u8, &nft.nft_id, &offer.nft_id)) {
                        if (offer.is_sell_offer) {
                            nft.owner = offer.destination orelse return error.InvalidOffer;
                        } else {
                            nft.owner = offer.owner;
                        }
                        break;
                    }
                }

                _ = self.offers.swapRemove(i);
                return;
            }
        }
        return error.OfferNotFound;
    }
};

/// Non-fungible token
pub const NFToken = struct {
    nft_id: [32]u8,
    owner: types.AccountID,
    issuer: types.AccountID,
    taxon: u32,
    sequence: u32,
    transfer_fee: u16 = 0, // In basis points (0-50000 = 0-50%)
    flags: NFTFlags = .{},
    uri: ?[]const u8 = null,
};

/// NFT flags
pub const NFTFlags = packed struct {
    burnable: bool = false,
    only_xrp: bool = false,
    trustline: bool = false,
    transferable: bool = true,
    _padding: u28 = 0,
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

/// NFTokenCancelOffer transaction - WEEK 3 DAY 19
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
        // Basic validation
        if (self.base.fee < types.MIN_TX_FEE) return error.InsufficientFee;
        if (self.base.sequence == 0) return error.InvalidSequence;
    }
};

/// NFTokenAcceptOffer transaction - WEEK 3 DAY 19
pub const NFTokenAcceptOfferTransaction = struct {
    base: types.Transaction,
    nft_offer_id: [32]u8, // Hash of the offer to accept
    broker_fee: ?types.Amount = null, // Optional broker fee

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
        // Basic validation
        if (self.base.fee < types.MIN_TX_FEE) return error.InsufficientFee;
        if (self.base.sequence == 0) return error.InvalidSequence;
    }
};

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
