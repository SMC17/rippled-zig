const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");

/// Decentralized Exchange - Order book implementation
pub const OrderBook = struct {
    allocator: std.mem.Allocator,
    offers: std.ArrayList(Offer),

    pub fn init(allocator: std.mem.Allocator) OrderBook {
        return OrderBook{
            .allocator = allocator,
            .offers = std.ArrayList(Offer).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *OrderBook) void {
        self.offers.deinit();
    }

    /// Create a new offer
    pub fn createOffer(self: *OrderBook, offer: Offer) !void {
        // Validate offer
        if (offer.taker_pays.isXRP() and offer.taker_gets.isXRP()) {
            return error.XRPToXRPOffer; // Can't exchange XRP for XRP
        }

        // Add to order book
        try self.offers.append(offer);

        // Try to cross offers
        try self.crossOffers();
    }

    /// Cancel an offer
    pub fn cancelOffer(self: *OrderBook, sequence: u32, account: types.AccountID) !void {
        var i: usize = 0;
        while (i < self.offers.items.len) {
            const offer = &self.offers.items[i];
            if (offer.sequence == sequence and std.mem.eql(u8, &offer.account, &account)) {
                _ = self.offers.swapRemove(i);
                return;
            }
            i += 1;
        }
        return error.OfferNotFound;
    }

    /// Cross offers (match buy and sell orders)
    fn crossOffers(self: *OrderBook) !void {
        // Simplified offer crossing
        // In production, this would match orders by price and execute trades
        _ = self;
    }

    /// Get offers for an account
    pub fn getOffersForAccount(self: *const OrderBook, account: types.AccountID) []const Offer {
        _ = account;
        return self.offers.items;
    }
};

/// An offer in the order book
pub const Offer = struct {
    account: types.AccountID,
    sequence: u32,
    taker_pays: types.Amount,
    taker_gets: types.Amount,
    expiration: ?i64 = null,
    offer_sequence: u32,

    /// Calculate the exchange rate
    pub fn getRate(self: Offer) f64 {
        // Simplified rate calculation
        _ = self;
        return 1.0;
    }
};

/// OfferCreate transaction
pub const OfferCreateTransaction = struct {
    base: types.Transaction,
    taker_pays: types.Amount,
    taker_gets: types.Amount,
    expiration: ?i64 = null,
    offer_sequence: ?u32 = null,

    pub fn create(
        account: types.AccountID,
        taker_pays: types.Amount,
        taker_gets: types.Amount,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) OfferCreateTransaction {
        return OfferCreateTransaction{
            .base = types.Transaction{
                .tx_type = .offer_create,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .taker_pays = taker_pays,
            .taker_gets = taker_gets,
        };
    }

    /// Validate the offer
    pub fn validate(self: *const OfferCreateTransaction) !void {
        // Can't exchange XRP for XRP
        if (self.taker_pays.isXRP() and self.taker_gets.isXRP()) {
            return error.XRPToXRPOffer;
        }

        // Amounts must be positive
        switch (self.taker_pays) {
            .xrp => |drops| if (drops == 0) return error.ZeroAmount,
            .iou => |iou| if (iou.value == 0) return error.ZeroAmount,
        }

        switch (self.taker_gets) {
            .xrp => |drops| if (drops == 0) return error.ZeroAmount,
            .iou => |iou| if (iou.value == 0) return error.ZeroAmount,
        }
    }
};

/// OfferCancel transaction
pub const OfferCancelTransaction = struct {
    base: types.Transaction,
    offer_sequence: u32,

    pub fn create(
        account: types.AccountID,
        offer_sequence: u32,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) OfferCancelTransaction {
        return OfferCancelTransaction{
            .base = types.Transaction{
                .tx_type = .offer_cancel,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .offer_sequence = offer_sequence,
        };
    }
};

test "order book creation" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    try std.testing.expectEqual(@as(usize, 0), book.offers.items.len);
}

test "offer create transaction" {
    const account = [_]u8{1} ** 20;
    const taker_pays = types.Amount.fromXRP(100 * types.XRP);
    const taker_gets = types.Amount{ .iou = .{
        .currency = .{ .standard = .{ 'U', 'S', 'D' } },
        .value = 100,
        .exponent = 0,
        .issuer = [_]u8{2} ** 20,
    } };

    const offer = OfferCreateTransaction.create(
        account,
        taker_pays,
        taker_gets,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try offer.validate();
    try std.testing.expectEqual(types.TransactionType.offer_create, offer.base.tx_type);
}

test "offer validation prevents XRP to XRP" {
    const account = [_]u8{1} ** 20;
    const taker_pays = types.Amount.fromXRP(100 * types.XRP);
    const taker_gets = types.Amount.fromXRP(50 * types.XRP); // Invalid: XRP to XRP

    const offer = OfferCreateTransaction.create(
        account,
        taker_pays,
        taker_gets,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try std.testing.expectError(error.XRPToXRPOffer, offer.validate());
}
