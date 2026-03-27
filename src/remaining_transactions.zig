const std = @import("std");
const types = @import("types.zig");
const nft = @import("nft.zig");

/// Remaining Transaction Types for Full rippled Parity
///
/// This module implements the 7 transaction types needed to reach 100% parity
/// NFTokenCancelOffer - Cancel an NFT offer
pub const NFTokenCancelOffer = struct {
    base: types.Transaction,
    nftoken_offers: []const [32]u8, // Array of offer IDs to cancel

    pub fn create(
        account: types.AccountID,
        nftoken_offers: []const [32]u8,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) NFTokenCancelOffer {
        return NFTokenCancelOffer{
            .base = types.Transaction{
                .tx_type = .nftoken_cancel_offer,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
                .txn_signature = null,
                .signers = null,
            },
            .nftoken_offers = nftoken_offers,
        };
    }

    pub fn validate(self: *const NFTokenCancelOffer) !void {
        // Must cancel at least one offer
        if (self.nftoken_offers.len == 0) {
            return error.NoOffersToCancel;
        }

        // Can't cancel more than 500 at once
        if (self.nftoken_offers.len > 500) {
            return error.TooManyOffers;
        }
    }
};

/// NFTokenAcceptOffer - Accept an NFT buy or sell offer
pub const NFTokenAcceptOffer = struct {
    base: types.Transaction,
    nftoken_sell_offer: ?[32]u8 = null,
    nftoken_buy_offer: ?[32]u8 = null,
    nftoken_broker_fee: ?types.Amount = null,

    pub fn create(
        account: types.AccountID,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) NFTokenAcceptOffer {
        return NFTokenAcceptOffer{
            .base = types.Transaction{
                .tx_type = .nftoken_accept_offer,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
                .txn_signature = null,
                .signers = null,
            },
        };
    }

    pub fn validate(self: *const NFTokenAcceptOffer) !void {
        // Must specify at least one offer
        if (self.nftoken_sell_offer == null and self.nftoken_buy_offer == null) {
            return error.NoOfferSpecified;
        }

        // Broker fee only valid when matching buy and sell
        if (self.nftoken_broker_fee != null) {
            if (self.nftoken_sell_offer == null or self.nftoken_buy_offer == null) {
                return error.BrokerFeeRequiresBothOffers;
            }
        }
    }
};

/// AccountDelete - Delete account and recover reserve
pub const AccountDelete = struct {
    base: types.Transaction,
    destination: types.AccountID,
    destination_tag: ?u32 = null,

    pub fn create(
        account: types.AccountID,
        destination: types.AccountID,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) AccountDelete {
        return AccountDelete{
            .base = types.Transaction{
                .tx_type = .account_delete,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
                .txn_signature = null,
                .signers = null,
            },
            .destination = destination,
        };
    }

    pub fn validate(self: *const AccountDelete) !void {
        // Cannot delete to self
        if (std.mem.eql(u8, &self.base.account.?, &self.destination)) {
            return error.CannotDeleteToSelf;
        }

        // Must have high sequence number (256 ledgers old minimum)
        if (self.base.sequence < 256) {
            return error.AccountTooNew;
        }
    }
};

/// SetRegularKey - Set a regular signing key for the account
pub const SetRegularKey = struct {
    base: types.Transaction,
    regular_key: ?types.AccountID = null, // null removes regular key

    pub fn create(
        account: types.AccountID,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) SetRegularKey {
        return SetRegularKey{
            .base = types.Transaction{
                .tx_type = .regular_key_set,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
                .txn_signature = null,
                .signers = null,
            },
        };
    }

    pub fn validate(self: *const SetRegularKey) !void {
        // If setting a key, cannot be the master key
        if (self.regular_key) |key| {
            if (std.mem.eql(u8, &key, &self.base.account.?)) {
                return error.RegularKeyCannotBeAccount;
            }
        }
    }
};

/// DepositPreauth - Preauthorize deposits from specific account
pub const DepositPreauth = struct {
    base: types.Transaction,
    authorize: ?types.AccountID = null,
    unauthorize: ?types.AccountID = null,

    pub fn create(
        account: types.AccountID,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) DepositPreauth {
        return DepositPreauth{
            .base = types.Transaction{
                .tx_type = .deposit_preauth,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
                .txn_signature = null,
                .signers = null,
            },
        };
    }

    pub fn validate(self: *const DepositPreauth) !void {
        // Must specify either authorize OR unauthorize, not both
        if (self.authorize != null and self.unauthorize != null) {
            return error.CannotAuthAndUnauth;
        }

        if (self.authorize == null and self.unauthorize == null) {
            return error.MustSpecifyAuthorizeOrUnauthorize;
        }

        // Cannot authorize/unauthorize self
        if (self.authorize) |auth| {
            if (std.mem.eql(u8, &auth, &self.base.account.?)) {
                return error.CannotPreauthSelf;
            }
        }

        if (self.unauthorize) |unauth| {
            if (std.mem.eql(u8, &unauth, &self.base.account.?)) {
                return error.CannotPreauthSelf;
            }
        }
    }
};

/// Clawback - Claw back issued currency tokens
pub const Clawback = struct {
    base: types.Transaction,
    amount: types.Amount,

    pub fn create(
        account: types.AccountID,
        amount: types.Amount,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) Clawback {
        return Clawback{
            .base = types.Transaction{
                .tx_type = .clawback,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
                .txn_signature = null,
                .signers = null,
            },
            .amount = amount,
        };
    }

    pub fn validate(self: *const Clawback) !void {
        // Can only claw back IOUs, not XRP
        if (self.amount.isXRP()) {
            return error.CannotClawbackXRP;
        }

        // Amount must be positive
        switch (self.amount) {
            .iou => |iou| {
                if (iou.value <= 0) {
                    return error.InvalidAmount;
                }
            },
            else => unreachable,
        }
    }
};

/// TicketCreate - Create sequence number tickets
pub const TicketCreate = struct {
    base: types.Transaction,
    ticket_count: u32,

    pub fn create(
        account: types.AccountID,
        ticket_count: u32,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) TicketCreate {
        return TicketCreate{
            .base = types.Transaction{
                .tx_type = .ticket_create,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
                .txn_signature = null,
                .signers = null,
            },
            .ticket_count = ticket_count,
        };
    }

    pub fn validate(self: *const TicketCreate) !void {
        // Must create at least 1 ticket
        if (self.ticket_count == 0) {
            return error.ZeroTickets;
        }

        // Can't create more than 250 at once
        if (self.ticket_count > 250) {
            return error.TooManyTickets;
        }
    }
};

test "nftoken cancel offer" {
    const account = [_]u8{1} ** 20;
    const offers = [_][32]u8{[_]u8{1} ** 32};

    const tx = NFTokenCancelOffer.create(
        account,
        &offers,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.nftoken_cancel_offer, tx.base.tx_type);
}

test "nftoken accept offer" {
    const account = [_]u8{1} ** 20;

    var tx = NFTokenAcceptOffer.create(
        account,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    // Must specify at least one offer
    try std.testing.expectError(error.NoOfferSpecified, tx.validate());

    // Add offer
    tx.nftoken_sell_offer = [_]u8{1} ** 32;
    try tx.validate();
}

test "account delete" {
    const account = [_]u8{1} ** 20;
    const destination = [_]u8{2} ** 20;

    const tx = AccountDelete.create(
        account,
        destination,
        types.MIN_TX_FEE,
        300, // Must be > 256
        [_]u8{0} ** 33,
    );

    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.account_delete, tx.base.tx_type);
}

test "set regular key" {
    const account = [_]u8{1} ** 20;

    var tx = SetRegularKey.create(
        account,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    // Can remove key (null is valid)
    try tx.validate();

    // Can set different key
    tx.regular_key = [_]u8{2} ** 20;
    try tx.validate();
}

test "deposit preauth" {
    const account = [_]u8{1} ** 20;

    var tx = DepositPreauth.create(
        account,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    // Must specify authorize or unauthorize
    try std.testing.expectError(error.MustSpecifyAuthorizeOrUnauthorize, tx.validate());

    // Authorize someone
    tx.authorize = [_]u8{2} ** 20;
    try tx.validate();
}

test "ticket create" {
    const account = [_]u8{1} ** 20;

    const tx = TicketCreate.create(
        account,
        10, // Create 10 tickets
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try tx.validate();
    try std.testing.expectEqual(@as(u32, 10), tx.ticket_count);
}
