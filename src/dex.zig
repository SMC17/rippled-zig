const std = @import("std");
const types = @import("types.zig");

// ---------------------------------------------------------------------------
// Quality (exchange rate) as a rational number to avoid floating-point
// non-determinism.  quality = taker_pays / taker_gets expressed as
// numerator / denominator (both u64).
// ---------------------------------------------------------------------------
pub const Quality = struct {
    num: u64, // taker_pays amount
    den: u64, // taker_gets amount

    /// Create a quality from raw amounts, extracting the u64 magnitude.
    pub fn fromAmounts(taker_pays: types.Amount, taker_gets: types.Amount) Quality {
        return .{
            .num = amountValue(taker_pays),
            .den = amountValue(taker_gets),
        };
    }

    /// a/b < c/d  iff  a*d < c*b  (using u128 to avoid overflow)
    pub fn lessThan(self: Quality, other: Quality) bool {
        const lhs: u128 = @as(u128, self.num) * @as(u128, other.den);
        const rhs: u128 = @as(u128, other.num) * @as(u128, self.den);
        return lhs < rhs;
    }

    pub fn equal(self: Quality, other: Quality) bool {
        const lhs: u128 = @as(u128, self.num) * @as(u128, other.den);
        const rhs: u128 = @as(u128, other.num) * @as(u128, self.den);
        return lhs == rhs;
    }

    /// True when a crossing is possible: ask_quality <= bid_quality
    /// i.e. the ask price is at or below what the bid is willing to pay.
    pub fn canCross(ask: Quality, bid: Quality) bool {
        // ask.num/ask.den <= bid.num/bid.den
        // ask.num * bid.den <= bid.num * ask.den
        const lhs: u128 = @as(u128, ask.num) * @as(u128, bid.den);
        const rhs: u128 = @as(u128, bid.num) * @as(u128, ask.den);
        return lhs <= rhs;
    }
};

/// Extract the u64 magnitude from an Amount.
fn amountValue(amt: types.Amount) u64 {
    return switch (amt) {
        .xrp => |d| d,
        .iou => |iou| if (iou.value >= 0) @intCast(iou.value) else @intCast(-iou.value),
    };
}

/// Set the u64 magnitude on an Amount, preserving its currency/issuer.
fn amountWithValue(template: types.Amount, val: u64) types.Amount {
    return switch (template) {
        .xrp => types.Amount{ .xrp = val },
        .iou => |iou| types.Amount{ .iou = .{
            .currency = iou.currency,
            .value = @intCast(val),
            .exponent = iou.exponent,
            .issuer = iou.issuer,
        } },
    };
}

// ---------------------------------------------------------------------------
// OfferCreate flags
// ---------------------------------------------------------------------------
pub const OfferFlag = struct {
    pub const tfPassive: u32 = 0x00010000;
    pub const tfImmediateOrCancel: u32 = 0x00020000;
    pub const tfFillOrKill: u32 = 0x00040000;
    pub const tfSell: u32 = 0x00080000;
};

// ---------------------------------------------------------------------------
// Offer
// ---------------------------------------------------------------------------

/// An offer in the order book
pub const Offer = struct {
    account: types.AccountID,
    sequence: u32,
    taker_pays: types.Amount, // what the offer creator wants to receive
    taker_gets: types.Amount, // what the offer creator is willing to give
    expiration: ?i64 = null,
    offer_sequence: u32,
    flags: u32 = 0,

    /// Quality = taker_pays / taker_gets  (lower is cheaper for the taker).
    pub fn quality(self: Offer) Quality {
        return Quality.fromAmounts(self.taker_pays, self.taker_gets);
    }

    /// Remaining taker_pays value.
    pub fn paysValue(self: Offer) u64 {
        return amountValue(self.taker_pays);
    }

    /// Remaining taker_gets value.
    pub fn getsValue(self: Offer) u64 {
        return amountValue(self.taker_gets);
    }
};

// ---------------------------------------------------------------------------
// Fill record
// ---------------------------------------------------------------------------
pub const Fill = struct {
    maker_account: types.AccountID,
    maker_sequence: u32,
    taker_account: types.AccountID,
    taker_sequence: u32,
    /// Amount the taker paid (received by the maker).
    taker_paid: u64,
    /// Amount the taker got (given up by the maker).
    taker_got: u64,
};

// ---------------------------------------------------------------------------
// OrderBook
// ---------------------------------------------------------------------------
pub const OrderBook = struct {
    allocator: std.mem.Allocator,
    /// All resting offers.  Kept sorted by (quality ASC, sequence ASC)
    /// so that the best price for a taker is at the front.
    offers: std.ArrayList(Offer),

    pub fn init(allocator: std.mem.Allocator) OrderBook {
        return OrderBook{
            .allocator = allocator,
            .offers = std.ArrayList(Offer).init(allocator),
        };
    }

    pub fn deinit(self: *OrderBook) void {
        self.offers.deinit();
    }

    // ------------------------------------------------------------------
    // Sorted insertion helpers
    // ------------------------------------------------------------------

    /// Insert an offer maintaining the sorted invariant.
    fn insertSorted(self: *OrderBook, offer: Offer) !void {
        const q = offer.quality();
        var pos: usize = 0;
        for (self.offers.items) |existing| {
            const eq = existing.quality();
            if (q.lessThan(eq)) break;
            if (q.equal(eq) and offer.sequence < existing.sequence) break;
            pos += 1;
        }
        try self.offers.insert(pos, offer);
    }

    // ------------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------------

    /// Create and possibly match a new offer.
    /// Returns the list of fills that resulted from matching.
    pub fn createOffer(self: *OrderBook, offer: Offer) !std.ArrayList(Fill) {
        // Validate: can't exchange XRP for XRP
        if (offer.taker_pays.isXRP() and offer.taker_gets.isXRP()) {
            return error.XRPToXRPOffer;
        }

        var fills = std.ArrayList(Fill).init(self.allocator);
        errdefer fills.deinit();

        const is_passive = (offer.flags & OfferFlag.tfPassive) != 0;
        const is_ioc = (offer.flags & OfferFlag.tfImmediateOrCancel) != 0;
        const is_fok = (offer.flags & OfferFlag.tfFillOrKill) != 0;

        // FillOrKill pre-check: verify that enough liquidity exists before
        // consuming anything.
        if (is_fok) {
            const needed = amountValue(offer.taker_gets);
            var available: u64 = 0;
            for (self.offers.items) |existing| {
                // Same crossing rules as matchOffer but read-only.
                if (std.mem.eql(u8, &existing.account, &offer.account)) continue;
                if (!offersOverlap(offer, existing)) continue;
                if (!Quality.canCross(existing.quality(), offer.quality())) break;
                available += existing.paysValue();
                if (available >= needed) break;
            }
            if (available < needed) {
                return error.FillOrKillInsufficient;
            }
        }

        // Passive offers skip matching.
        if (!is_passive) {
            try self.matchOffer(&fills, offer);
        }

        // Determine remaining amount after fills.
        var remaining_gets = amountValue(offer.taker_gets);
        var remaining_pays = amountValue(offer.taker_pays);
        for (fills.items) |f| {
            remaining_gets -|= f.taker_got;
            remaining_pays -|= f.taker_paid;
        }

        // IOC: don't place remainder on book.
        if (is_ioc) {
            return fills;
        }

        // Place remainder on book if there is any.
        if (remaining_gets > 0 and remaining_pays > 0) {
            const rest = Offer{
                .account = offer.account,
                .sequence = offer.sequence,
                .taker_pays = amountWithValue(offer.taker_pays, remaining_pays),
                .taker_gets = amountWithValue(offer.taker_gets, remaining_gets),
                .expiration = offer.expiration,
                .offer_sequence = offer.offer_sequence,
                .flags = offer.flags,
            };
            try self.insertSorted(rest);
        }

        return fills;
    }

    /// Cancel an offer
    pub fn cancelOffer(self: *OrderBook, sequence: u32, account: types.AccountID) !void {
        var i: usize = 0;
        while (i < self.offers.items.len) {
            const o = &self.offers.items[i];
            if (o.sequence == sequence and std.mem.eql(u8, &o.account, &account)) {
                _ = self.offers.orderedRemove(i);
                return;
            }
            i += 1;
        }
        return error.OfferNotFound;
    }

    /// Get offers for an account
    pub fn getOffersForAccount(self: *const OrderBook, account: types.AccountID) []const Offer {
        _ = account;
        return self.offers.items;
    }

    // ------------------------------------------------------------------
    // Matching engine (private)
    // ------------------------------------------------------------------

    /// Walk through the resting book and consume offers that cross with
    /// `incoming`.  Fills are appended to `fills`.
    fn matchOffer(self: *OrderBook, fills: *std.ArrayList(Fill), incoming: Offer) !void {
        const incoming_q = incoming.quality();
        var remaining_gets = amountValue(incoming.taker_gets);
        var remaining_pays = amountValue(incoming.taker_pays);

        var i: usize = 0;
        while (i < self.offers.items.len) {
            if (remaining_gets == 0 or remaining_pays == 0) break;

            const existing = &self.offers.items[i];

            // Only match offers in the same market (overlapping currency pair).
            if (!offersOverlap(incoming, existing.*)) {
                i += 1;
                continue;
            }

            // Best resting price worse than incoming limit => done.
            if (!Quality.canCross(existing.quality(), incoming_q)) {
                break;
            }

            // Self-crossing prevention.
            if (std.mem.eql(u8, &existing.account, &incoming.account)) {
                i += 1;
                continue;
            }

            // Determine fill amounts.
            //
            // Naming clarification:
            //   existing.taker_pays = what someone taking this offer would pay = what the maker wants to receive
            //   existing.taker_gets = what someone taking this offer would get = what the maker is giving up
            //
            // For the incoming offer:
            //   incoming.taker_pays = what the incoming taker wants to receive from the match
            //   incoming.taker_gets = what the incoming taker is willing to give
            //
            // A crossing means: the existing offer's taker_gets (what the maker gives up)
            // is the same asset the incoming offer's taker_pays (what the taker wants).
            // And the existing offer's taker_pays (what the maker wants) is the same asset
            // the incoming offer's taker_gets (what the taker gives).
            //
            // So:
            //   taker_got  = min(existing.taker_gets value, remaining_pays of incoming)  -- NO
            // Let me re-think with the XRPL semantics:
            //
            // existing offer sits on book:
            //   maker sells  existing.taker_gets  (gives this to the taker)
            //   maker buys   existing.taker_pays  (receives this from the taker)
            //
            // incoming offer (taker):
            //   taker sells  incoming.taker_gets  (gives this to the maker)
            //   taker buys   incoming.taker_pays  (receives this from the maker, but taker_pays is what taker pays... )
            //
            // Actually in XRPL:
            //   OfferCreate:  taker_pays = what you want,  taker_gets = what you give up
            // Wait no -- the naming is from the perspective of a *future taker* of this offer:
            //   taker_pays = what a taker would pay to take this offer = what the creator receives
            //   taker_gets = what a taker would get from this offer = what the creator gives up
            //
            // So for the INCOMING offer (which is itself also described from its taker's perspective):
            //   incoming.taker_pays = what a future taker of *this* offer would pay
            //   incoming.taker_gets = what a future taker of *this* offer would get
            //
            // But when the incoming offer crosses an existing one, the incoming offer's CREATOR
            // is acting as the taker of the existing offer.  So:
            //   The incoming creator pays:  existing.taker_pays amount (in that asset)
            //   The incoming creator gets:  existing.taker_gets amount (in that asset)
            //
            // For the crossing to work:
            //   existing.taker_pays asset == incoming.taker_gets asset  (what taker gives = what maker wants)
            //   existing.taker_gets asset == incoming.taker_pays asset  (what taker receives = what maker sells)
            //
            // WAIT -- that means the taker of the existing offer pays the existing.taker_pays
            // and gets the existing.taker_gets.  The incoming offer CREATOR is acting as taker.
            //
            // The incoming creator wants to end up having paid incoming.taker_gets and received
            // incoming.taker_pays.  But incoming is described from the *taker's* perspective too.
            // Actually no, from the *creator's* perspective:
            //   "I create an offer.  taker_pays = USD 100, taker_gets = XRP 50"
            //   This means: I'm selling 50 XRP, and a taker would pay me 100 USD for it.
            //   Creator gives up XRP 50, creator receives USD 100.
            //
            // So creator gives up taker_gets, creator receives taker_pays.
            //
            // For the incoming offer's creator:
            //   gives up: incoming.taker_gets amount
            //   receives: incoming.taker_pays amount  (but really this is the desired amount, may get partially filled)
            //
            // For the existing offer's creator (maker):
            //   gives up: existing.taker_gets amount
            //   receives: existing.taker_pays amount
            //
            // Crossing: incoming creator takes the existing offer.
            //   incoming creator pays (to maker): min of what maker wants vs what incoming creator can give
            //   incoming creator gets (from maker): proportional amount based on existing offer's rate
            //
            // What the maker wants = existing.taker_pays value = what the taker pays
            // What the incoming creator can give = remaining_gets (remaining of incoming.taker_gets)
            //
            // These must be the same asset for crossing. Already checked by offersOverlap.

            // Amount the taker (incoming creator) pays to the maker:
            // Limited by: (a) what maker still wants, (b) what taker can still give
            const taker_pays_amount = @min(existing.paysValue(), remaining_gets);

            // Amount the taker (incoming creator) gets from the maker:
            // Calculated at the existing offer's rate.
            // existing rate: taker pays existing.taker_pays to get existing.taker_gets
            // So for taker_pays_amount paid, taker gets:
            //   taker_gets_amount = taker_pays_amount * existing.taker_gets / existing.taker_pays
            // But also limited by what the maker has left (existing.getsValue).
            const eg = existing.getsValue();
            const ep = existing.paysValue();
            var taker_gets_amount: u64 = 0;
            if (ep > 0) {
                // Use u128 for intermediate to avoid overflow
                taker_gets_amount = @intCast(@min(
                    @as(u128, eg),
                    (@as(u128, taker_pays_amount) * @as(u128, eg) + @as(u128, ep) - 1) / @as(u128, ep),
                ));
            }
            // Also limit by what the taker still wants to receive
            taker_gets_amount = @min(taker_gets_amount, remaining_pays);

            if (taker_pays_amount == 0 or taker_gets_amount == 0) {
                i += 1;
                continue;
            }

            // Record the fill.
            try fills.append(Fill{
                .maker_account = existing.account,
                .maker_sequence = existing.sequence,
                .taker_account = incoming.account,
                .taker_sequence = incoming.sequence,
                .taker_paid = taker_pays_amount,
                .taker_got = taker_gets_amount,
            });

            remaining_gets -= taker_pays_amount;
            remaining_pays -= taker_gets_amount;

            // Update or remove the existing offer.
            const new_ep = ep - taker_pays_amount;
            const new_eg = if (eg >= taker_gets_amount) eg - taker_gets_amount else 0;
            if (new_ep == 0 or new_eg == 0) {
                // Fully consumed.
                _ = self.offers.orderedRemove(i);
                // don't increment i
            } else {
                // Partially consumed -- update in place.
                existing.taker_pays = amountWithValue(existing.taker_pays, new_ep);
                existing.taker_gets = amountWithValue(existing.taker_gets, new_eg);
                i += 1;
            }
        }
    }
};

/// Check whether two offers are in overlapping markets (opposite sides of
/// the same currency pair).  The existing offer's taker_pays asset must
/// equal the incoming offer's taker_gets asset, and vice-versa.
fn offersOverlap(incoming: Offer, existing: Offer) bool {
    return sameAsset(existing.taker_pays, incoming.taker_gets) and
        sameAsset(existing.taker_gets, incoming.taker_pays);
}

fn sameAsset(a: types.Amount, b: types.Amount) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) return false;
    switch (a) {
        .xrp => return true,
        .iou => |ia| {
            const ib = b.iou;
            return std.meta.activeTag(ia.currency) == std.meta.activeTag(ib.currency) and
                currencyEqual(ia.currency, ib.currency) and
                std.mem.eql(u8, &ia.issuer, &ib.issuer);
        },
    }
}

fn currencyEqual(a: types.Currency, b: types.Currency) bool {
    const ta = std.meta.activeTag(a);
    const tb = std.meta.activeTag(b);
    if (ta != tb) return false;
    return switch (a) {
        .xrp => true,
        .standard => |sa| std.mem.eql(u8, &sa, &b.standard),
        .custom => |ca| std.mem.eql(u8, &ca, &b.custom),
    };
}

// ---------------------------------------------------------------------------
// Autobridging through XRP
// ---------------------------------------------------------------------------

/// Attempt to autobridge a trade of IOU_A -> IOU_B through XRP.
/// Compares the direct IOU_A/IOU_B book against the synthetic path
/// IOU_A -> XRP -> IOU_B and returns the better effective quality.
///
/// `book_ab` is the direct book, `book_axrp` is the IOU_A/XRP book,
/// `book_xrpb` is the XRP/IOU_B book.
///
/// Returns the best effective quality (lower = better for taker) and
/// whether the bridged path was preferred.
pub const BridgeResult = struct {
    quality: Quality,
    use_bridge: bool,
};

pub fn autobridgeQuality(
    book_ab: *const OrderBook,
    book_a_xrp: *const OrderBook,
    book_xrp_b: *const OrderBook,
) ?BridgeResult {
    // Best direct quality (first offer in sorted book).
    const direct_q: ?Quality = if (book_ab.offers.items.len > 0)
        book_ab.offers.items[0].quality()
    else
        null;

    // Best bridged quality = quality(IOU_A/XRP) * quality(XRP/IOU_B)
    // q1 = a_pay / a_get,  q2 = b_pay / b_get
    // combined: (a_pay * b_pay) / (a_get * b_get)
    const bridged_q: ?Quality = blk: {
        if (book_a_xrp.offers.items.len == 0) break :blk null;
        if (book_xrp_b.offers.items.len == 0) break :blk null;
        const q1 = book_a_xrp.offers.items[0].quality();
        const q2 = book_xrp_b.offers.items[0].quality();
        break :blk Quality{
            .num = q1.num *| q2.num,
            .den = q1.den *| q2.den,
        };
    };

    if (direct_q) |dq| {
        if (bridged_q) |bq| {
            if (bq.lessThan(dq)) {
                return BridgeResult{ .quality = bq, .use_bridge = true };
            } else {
                return BridgeResult{ .quality = dq, .use_bridge = false };
            }
        }
        return BridgeResult{ .quality = dq, .use_bridge = false };
    } else if (bridged_q) |bq| {
        return BridgeResult{ .quality = bq, .use_bridge = true };
    }
    return null;
}

// ---------------------------------------------------------------------------
// OfferCreate / OfferCancel transaction wrappers (kept for compatibility)
// ---------------------------------------------------------------------------

/// OfferCreate transaction
pub const OfferCreateTransaction = struct {
    base: types.Transaction,
    taker_pays: types.Amount,
    taker_gets: types.Amount,
    expiration: ?i64 = null,
    offer_sequence: ?u32 = null,
    flags: u32 = 0,

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
        if (self.taker_pays.isXRP() and self.taker_gets.isXRP()) {
            return error.XRPToXRPOffer;
        }
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

// ===========================================================================
// Tests
// ===========================================================================

// Helper to build IOU amounts easily in tests.
fn makeIOU(comptime currency_str: *const [3]u8, issuer_byte: u8, value: i64) types.Amount {
    return types.Amount{ .iou = .{
        .currency = .{ .standard = currency_str.* },
        .value = value,
        .exponent = 0,
        .issuer = [_]u8{issuer_byte} ** 20,
    } };
}

// ── Existing tests (preserved) ────────────────────────────────────────────

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
    const taker_gets = types.Amount.fromXRP(50 * types.XRP);

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

// ── New matching-engine tests ─────────────────────────────────────────────

test "simple offer matching - buy meets sell" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    const alice = [_]u8{1} ** 20;
    const bob = [_]u8{2} ** 20;

    // Alice: sell 100 USD for 50 XRP  (quality = 50/100 = 0.5 XRP per USD)
    // taker_pays = XRP 50 (what a taker pays), taker_gets = USD 100 (what a taker gets)
    const sell = Offer{
        .account = alice,
        .sequence = 1,
        .taker_pays = types.Amount.fromXRP(50),
        .taker_gets = makeIOU("USD", 0xAA, 100),
        .offer_sequence = 1,
    };
    var fills1 = try book.createOffer(sell);
    defer fills1.deinit();
    try std.testing.expectEqual(@as(usize, 0), fills1.items.len);
    try std.testing.expectEqual(@as(usize, 1), book.offers.items.len);

    // Bob: buy 100 USD for 50 XRP  (opposite side)
    // taker_pays = USD 100, taker_gets = XRP 50
    const buy = Offer{
        .account = bob,
        .sequence = 2,
        .taker_pays = makeIOU("USD", 0xAA, 100),
        .taker_gets = types.Amount.fromXRP(50),
        .offer_sequence = 2,
    };
    var fills2 = try book.createOffer(buy);
    defer fills2.deinit();

    try std.testing.expectEqual(@as(usize, 1), fills2.items.len);
    try std.testing.expectEqual(@as(u64, 50), fills2.items[0].taker_paid);
    try std.testing.expectEqual(@as(u64, 100), fills2.items[0].taker_got);
    // Book should be empty after full cross.
    try std.testing.expectEqual(@as(usize, 0), book.offers.items.len);
}

test "partial fill - big offer meets small offer" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    const alice = [_]u8{1} ** 20;
    const bob = [_]u8{2} ** 20;

    // Alice: sell 200 USD for 100 XRP
    const big = Offer{
        .account = alice,
        .sequence = 1,
        .taker_pays = types.Amount.fromXRP(100),
        .taker_gets = makeIOU("USD", 0xAA, 200),
        .offer_sequence = 1,
    };
    var f1 = try book.createOffer(big);
    defer f1.deinit();

    // Bob: buy 100 USD for 50 XRP  (half of Alice's offer)
    const small = Offer{
        .account = bob,
        .sequence = 2,
        .taker_pays = makeIOU("USD", 0xAA, 100),
        .taker_gets = types.Amount.fromXRP(50),
        .offer_sequence = 2,
    };
    var f2 = try book.createOffer(small);
    defer f2.deinit();

    try std.testing.expectEqual(@as(usize, 1), f2.items.len);
    try std.testing.expectEqual(@as(u64, 50), f2.items[0].taker_paid);
    try std.testing.expectEqual(@as(u64, 100), f2.items[0].taker_got);

    // Alice's offer should remain with half left.
    try std.testing.expectEqual(@as(usize, 1), book.offers.items.len);
    try std.testing.expectEqual(@as(u64, 50), amountValue(book.offers.items[0].taker_pays));
    try std.testing.expectEqual(@as(u64, 100), amountValue(book.offers.items[0].taker_gets));
}

test "price-time priority" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    const alice = [_]u8{1} ** 20;
    const bob = [_]u8{2} ** 20;
    const carol = [_]u8{3} ** 20;

    // Alice: sell 100 USD for 60 XRP  (quality 60/100 = 0.6)
    var f1 = try book.createOffer(Offer{
        .account = alice,
        .sequence = 1,
        .taker_pays = types.Amount.fromXRP(60),
        .taker_gets = makeIOU("USD", 0xAA, 100),
        .offer_sequence = 1,
    });
    defer f1.deinit();

    // Bob: sell 100 USD for 50 XRP  (quality 50/100 = 0.5, better price)
    var f2 = try book.createOffer(Offer{
        .account = bob,
        .sequence = 2,
        .taker_pays = types.Amount.fromXRP(50),
        .taker_gets = makeIOU("USD", 0xAA, 100),
        .offer_sequence = 2,
    });
    defer f2.deinit();

    // Book should be sorted: Bob (0.5) before Alice (0.6)
    try std.testing.expectEqual(@as(usize, 2), book.offers.items.len);
    try std.testing.expect(std.mem.eql(u8, &book.offers.items[0].account, &bob));
    try std.testing.expect(std.mem.eql(u8, &book.offers.items[1].account, &alice));

    // Carol: buy 100 USD for 60 XRP -- should match Bob first (better price)
    var f3 = try book.createOffer(Offer{
        .account = carol,
        .sequence = 3,
        .taker_pays = makeIOU("USD", 0xAA, 100),
        .taker_gets = types.Amount.fromXRP(60),
        .offer_sequence = 3,
    });
    defer f3.deinit();

    try std.testing.expectEqual(@as(usize, 1), f3.items.len);
    // Matched against Bob
    try std.testing.expect(std.mem.eql(u8, &f3.items[0].maker_account, &bob));
    // Alice's offer should still be on the book
    try std.testing.expectEqual(@as(usize, 1), book.offers.items.len);
    try std.testing.expect(std.mem.eql(u8, &book.offers.items[0].account, &alice));
}

test "self-crossing prevention" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    const alice = [_]u8{1} ** 20;

    // Alice places a sell
    var f1 = try book.createOffer(Offer{
        .account = alice,
        .sequence = 1,
        .taker_pays = types.Amount.fromXRP(50),
        .taker_gets = makeIOU("USD", 0xAA, 100),
        .offer_sequence = 1,
    });
    defer f1.deinit();

    // Alice places the opposite side -- should NOT match herself
    var f2 = try book.createOffer(Offer{
        .account = alice,
        .sequence = 2,
        .taker_pays = makeIOU("USD", 0xAA, 100),
        .taker_gets = types.Amount.fromXRP(50),
        .offer_sequence = 2,
    });
    defer f2.deinit();

    try std.testing.expectEqual(@as(usize, 0), f2.items.len);
    // Both offers remain on the book.
    try std.testing.expectEqual(@as(usize, 2), book.offers.items.len);
}

test "passive offer placement" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    const alice = [_]u8{1} ** 20;
    const bob = [_]u8{2} ** 20;

    // Alice: sell 100 USD for 50 XRP
    var f1 = try book.createOffer(Offer{
        .account = alice,
        .sequence = 1,
        .taker_pays = types.Amount.fromXRP(50),
        .taker_gets = makeIOU("USD", 0xAA, 100),
        .offer_sequence = 1,
    });
    defer f1.deinit();

    // Bob: passive buy -- should NOT match, just sit on book
    var f2 = try book.createOffer(Offer{
        .account = bob,
        .sequence = 2,
        .taker_pays = makeIOU("USD", 0xAA, 100),
        .taker_gets = types.Amount.fromXRP(50),
        .offer_sequence = 2,
        .flags = OfferFlag.tfPassive,
    });
    defer f2.deinit();

    try std.testing.expectEqual(@as(usize, 0), f2.items.len);
    try std.testing.expectEqual(@as(usize, 2), book.offers.items.len);
}

test "fill-or-kill rejection when liquidity insufficient" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    const alice = [_]u8{1} ** 20;
    const bob = [_]u8{2} ** 20;

    // Alice: sell 50 USD for 25 XRP
    var f1 = try book.createOffer(Offer{
        .account = alice,
        .sequence = 1,
        .taker_pays = types.Amount.fromXRP(25),
        .taker_gets = makeIOU("USD", 0xAA, 50),
        .offer_sequence = 1,
    });
    defer f1.deinit();

    // Bob: FOK buy 100 USD for 50 XRP -- not enough liquidity
    const result = book.createOffer(Offer{
        .account = bob,
        .sequence = 2,
        .taker_pays = makeIOU("USD", 0xAA, 100),
        .taker_gets = types.Amount.fromXRP(50),
        .offer_sequence = 2,
        .flags = OfferFlag.tfFillOrKill,
    });
    try std.testing.expectError(error.FillOrKillInsufficient, result);

    // Alice's offer should still be intact.
    try std.testing.expectEqual(@as(usize, 1), book.offers.items.len);
    try std.testing.expectEqual(@as(u64, 50), amountValue(book.offers.items[0].taker_gets));
}

test "immediate-or-cancel partial fill" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    const alice = [_]u8{1} ** 20;
    const bob = [_]u8{2} ** 20;

    // Alice: sell 50 USD for 25 XRP
    var f1 = try book.createOffer(Offer{
        .account = alice,
        .sequence = 1,
        .taker_pays = types.Amount.fromXRP(25),
        .taker_gets = makeIOU("USD", 0xAA, 50),
        .offer_sequence = 1,
    });
    defer f1.deinit();

    // Bob: IOC buy 100 USD for 50 XRP -- only 50 USD available
    var f2 = try book.createOffer(Offer{
        .account = bob,
        .sequence = 2,
        .taker_pays = makeIOU("USD", 0xAA, 100),
        .taker_gets = types.Amount.fromXRP(50),
        .offer_sequence = 2,
        .flags = OfferFlag.tfImmediateOrCancel,
    });
    defer f2.deinit();

    // Should get a partial fill
    try std.testing.expectEqual(@as(usize, 1), f2.items.len);
    try std.testing.expectEqual(@as(u64, 25), f2.items[0].taker_paid);
    try std.testing.expectEqual(@as(u64, 50), f2.items[0].taker_got);
    // Remainder should NOT be on the book (IOC).
    try std.testing.expectEqual(@as(usize, 0), book.offers.items.len);
}

test "multiple fills in sequence" {
    const allocator = std.testing.allocator;
    var book = OrderBook.init(allocator);
    defer book.deinit();

    const alice = [_]u8{1} ** 20;
    const bob = [_]u8{2} ** 20;
    const carol = [_]u8{3} ** 20;
    const dave = [_]u8{4} ** 20;

    // Alice: sell 50 USD for 25 XRP
    var f1 = try book.createOffer(Offer{
        .account = alice,
        .sequence = 1,
        .taker_pays = types.Amount.fromXRP(25),
        .taker_gets = makeIOU("USD", 0xAA, 50),
        .offer_sequence = 1,
    });
    defer f1.deinit();

    // Bob: sell 60 USD for 30 XRP  (same rate)
    var f2 = try book.createOffer(Offer{
        .account = bob,
        .sequence = 2,
        .taker_pays = types.Amount.fromXRP(30),
        .taker_gets = makeIOU("USD", 0xAA, 60),
        .offer_sequence = 2,
    });
    defer f2.deinit();

    // Carol: sell 40 USD for 20 XRP  (same rate)
    var f3 = try book.createOffer(Offer{
        .account = carol,
        .sequence = 3,
        .taker_pays = types.Amount.fromXRP(20),
        .taker_gets = makeIOU("USD", 0xAA, 40),
        .offer_sequence = 3,
    });
    defer f3.deinit();

    try std.testing.expectEqual(@as(usize, 3), book.offers.items.len);

    // Dave: buy 130 USD for 65 XRP -- should consume all three offers
    var f4 = try book.createOffer(Offer{
        .account = dave,
        .sequence = 4,
        .taker_pays = makeIOU("USD", 0xAA, 150),
        .taker_gets = types.Amount.fromXRP(75),
        .offer_sequence = 4,
    });
    defer f4.deinit();

    try std.testing.expectEqual(@as(usize, 3), f4.items.len);
    // All three makers consumed.  Sum: 25+30+20 = 75 XRP paid, 50+60+40 = 150 USD got.
    var total_paid: u64 = 0;
    var total_got: u64 = 0;
    for (f4.items) |f| {
        total_paid += f.taker_paid;
        total_got += f.taker_got;
    }
    try std.testing.expectEqual(@as(u64, 75), total_paid);
    try std.testing.expectEqual(@as(u64, 150), total_got);
    // Book should be empty.
    try std.testing.expectEqual(@as(usize, 0), book.offers.items.len);
}

test "autobridge prefers better path" {
    const allocator = std.testing.allocator;

    // Direct book: IOU_A -> IOU_B at quality 10/5 = 2.0
    var book_ab = OrderBook.init(allocator);
    defer book_ab.deinit();
    try book_ab.insertSorted(Offer{
        .account = [_]u8{1} ** 20,
        .sequence = 1,
        .taker_pays = makeIOU("AAA", 0xA1, 10),
        .taker_gets = makeIOU("BBB", 0xB1, 5),
        .offer_sequence = 1,
    });

    // IOU_A -> XRP book: quality 3/10 = 0.3
    var book_a_xrp = OrderBook.init(allocator);
    defer book_a_xrp.deinit();
    try book_a_xrp.insertSorted(Offer{
        .account = [_]u8{2} ** 20,
        .sequence = 2,
        .taker_pays = makeIOU("AAA", 0xA1, 3),
        .taker_gets = types.Amount.fromXRP(10),
        .offer_sequence = 2,
    });

    // XRP -> IOU_B book: quality 4/10 = 0.4
    var book_xrp_b = OrderBook.init(allocator);
    defer book_xrp_b.deinit();
    try book_xrp_b.insertSorted(Offer{
        .account = [_]u8{3} ** 20,
        .sequence = 3,
        .taker_pays = types.Amount.fromXRP(4),
        .taker_gets = makeIOU("BBB", 0xB1, 10),
        .offer_sequence = 3,
    });

    // Bridged quality = 0.3 * 0.4 = 0.12, direct = 2.0 => bridge wins.
    const result = autobridgeQuality(&book_ab, &book_a_xrp, &book_xrp_b);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.use_bridge);
}

test "quality comparison" {
    // 1/2 < 3/4
    const q1 = Quality{ .num = 1, .den = 2 };
    const q2 = Quality{ .num = 3, .den = 4 };
    try std.testing.expect(q1.lessThan(q2));
    try std.testing.expect(!q2.lessThan(q1));

    // 2/4 == 1/2
    const q3 = Quality{ .num = 2, .den = 4 };
    try std.testing.expect(q1.equal(q3));
}
