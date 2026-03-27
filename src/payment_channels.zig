const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");

/// Payment Channels - Asynchronous XRP payment streams
pub const PaymentChannelManager = struct {
    allocator: std.mem.Allocator,
    channels: std.ArrayList(PaymentChannel),

    pub fn init(allocator: std.mem.Allocator) PaymentChannelManager {
        return PaymentChannelManager{
            .allocator = allocator,
            .channels = std.ArrayList(PaymentChannel).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *PaymentChannelManager) void {
        self.channels.deinit();
    }

    /// Create a new payment channel
    pub fn createChannel(self: *PaymentChannelManager, channel: PaymentChannel) !void {
        // Validate channel
        if (channel.amount == 0) return error.ZeroAmount;
        if (channel.settle_delay > 86400 * 30) return error.SettleDelayTooLarge; // Max 30 days

        try self.channels.append(channel);
    }

    /// Fund an existing channel
    pub fn fundChannel(self: *PaymentChannelManager, channel_id: [32]u8, amount: types.Drops) !void {
        for (self.channels.items) |*channel| {
            if (std.mem.eql(u8, &channel.channel_id, &channel_id)) {
                channel.amount += amount;
                return;
            }
        }
        return error.ChannelNotFound;
    }

    /// Claim from a channel
    pub fn claimChannel(
        self: *PaymentChannelManager,
        channel_id: [32]u8,
        balance: types.Drops,
        signature: []const u8,
    ) !types.Drops {
        for (self.channels.items, 0..) |channel, i| {
            if (std.mem.eql(u8, &channel.channel_id, &channel_id)) {
                // Verify signature
                // TODO: Implement signature verification against channel public key
                _ = signature;

                // Check claim amount
                if (balance > channel.amount) return error.InsufficientChannelBalance;
                if (balance <= channel.balance) return error.BalanceNotIncreased;

                const claim_amount = balance - channel.balance;

                // Check if closing
                if (balance == channel.amount) {
                    _ = self.channels.swapRemove(i);
                } else {
                    self.channels.items[i].balance = balance;
                }

                return claim_amount;
            }
        }
        return error.ChannelNotFound;
    }
};

/// A payment channel
pub const PaymentChannel = struct {
    channel_id: [32]u8,
    account: types.AccountID,
    destination: types.AccountID,
    amount: types.Drops,
    balance: types.Drops,
    settle_delay: u32,
    public_key: [33]u8,
    cancel_after: ?i64 = null,
    destination_tag: ?u32 = null,
    expiration: ?i64 = null,
};

/// PaymentChannelCreate transaction
pub const PaymentChannelCreateTransaction = struct {
    base: types.Transaction,
    destination: types.AccountID,
    amount: types.Drops,
    settle_delay: u32,
    public_key: [33]u8,
    cancel_after: ?i64 = null,
    destination_tag: ?u32 = null,

    pub fn create(
        account: types.AccountID,
        destination: types.AccountID,
        amount: types.Drops,
        settle_delay: u32,
        public_key: [33]u8,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) PaymentChannelCreateTransaction {
        return PaymentChannelCreateTransaction{
            .base = types.Transaction{
                .tx_type = .payment_channel_create,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .destination = destination,
            .amount = amount,
            .settle_delay = settle_delay,
            .public_key = public_key,
        };
    }

    pub fn validate(self: *const PaymentChannelCreateTransaction) !void {
        if (self.amount == 0) return error.ZeroAmount;
        if (self.settle_delay == 0) return error.InvalidSettleDelay;
        if (self.settle_delay > 86400 * 30) return error.SettleDelayTooLarge;
    }
};

/// PaymentChannelFund transaction
pub const PaymentChannelFundTransaction = struct {
    base: types.Transaction,
    channel: [32]u8,
    amount: types.Drops,
    expiration: ?i64 = null,

    pub fn create(
        account: types.AccountID,
        channel: [32]u8,
        amount: types.Drops,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) PaymentChannelFundTransaction {
        return PaymentChannelFundTransaction{
            .base = types.Transaction{
                .tx_type = .payment_channel_fund,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .channel = channel,
            .amount = amount,
        };
    }
};

/// PaymentChannelClaim transaction
pub const PaymentChannelClaimTransaction = struct {
    base: types.Transaction,
    channel: [32]u8,
    balance: ?types.Drops = null,
    amount: ?types.Drops = null,
    signature: ?[]const u8 = null,
    public_key: ?[33]u8 = null,

    pub fn create(
        account: types.AccountID,
        channel: [32]u8,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) PaymentChannelClaimTransaction {
        return PaymentChannelClaimTransaction{
            .base = types.Transaction{
                .tx_type = .payment_channel_claim,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .channel = channel,
        };
    }
};

test "payment channel creation" {
    const allocator = std.testing.allocator;
    var manager = PaymentChannelManager.init(allocator);
    defer manager.deinit();

    const channel = PaymentChannel{
        .channel_id = [_]u8{1} ** 32,
        .account = [_]u8{1} ** 20,
        .destination = [_]u8{2} ** 20,
        .amount = 1000 * types.XRP,
        .balance = 0,
        .settle_delay = 3600,
        .public_key = [_]u8{0} ** 33,
    };

    try manager.createChannel(channel);
    try std.testing.expectEqual(@as(usize, 1), manager.channels.items.len);
}

test "payment channel transaction" {
    const account = [_]u8{1} ** 20;
    const destination = [_]u8{2} ** 20;
    const public_key = [_]u8{0} ** 33;

    const tx = PaymentChannelCreateTransaction.create(
        account,
        destination,
        1000 * types.XRP,
        3600,
        public_key,
        types.MIN_TX_FEE,
        1,
        public_key,
    );

    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.payment_channel_create, tx.base.tx_type);
}
