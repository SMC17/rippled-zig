const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const ledger = @import("ledger.zig");
const canonical = @import("canonical.zig");

fn serializeBaseFields(serializer: *canonical.CanonicalSerializer, base: *const types.Transaction) !void {
    try serializer.addUInt16(2, @intFromEnum(base.tx_type));
    try serializer.addUInt32(4, base.sequence);
    // Fee is an Amount field (type 6, field 8) in XRPL
    try serializer.addXRPAmount(8, base.fee);
    try serializer.addAccountID(1, base.account);
}

fn serializeAmountField(serializer: *canonical.CanonicalSerializer, field_code: u8, amount: types.Amount) !void {
    switch (amount) {
        .xrp => |drops| try serializer.addXRPAmount(field_code, drops),
        .iou => return error.UnsupportedAmountEncoding,
    }
}

fn expectSerializedHex(actual: []const u8, expected_hex: []const u8) !void {
    var expected: [256]u8 = undefined;
    if (expected_hex.len % 2 != 0) return error.InvalidHexLength;
    const expected_len = expected_hex.len / 2;
    if (expected_len > expected.len) return error.ExpectedHexTooLong;
    _ = try std.fmt.hexToBytes(expected[0..expected_len], expected_hex);
    try std.testing.expectEqualSlices(u8, expected[0..expected_len], actual);
}

/// Transaction validation and processing
pub const TransactionProcessor = struct {
    allocator: std.mem.Allocator,
    pending_transactions: std.ArrayList(types.Transaction),

    pub fn init(allocator: std.mem.Allocator) !TransactionProcessor {
        return TransactionProcessor{
            .allocator = allocator,
            .pending_transactions = try std.ArrayList(types.Transaction).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *TransactionProcessor) void {
        self.pending_transactions.deinit();
    }

    /// Validate a transaction
    pub fn validateTransaction(self: *const TransactionProcessor, tx: *const types.Transaction, account_state: *const ledger.AccountState) !types.TransactionResult {
        _ = self;

        // Check if account exists
        const account = account_state.getAccount(tx.account) orelse {
            return .tel_local_error;
        };

        // Validate fee
        if (tx.fee < types.MIN_TX_FEE) {
            return .tem_malformed;
        }

        // Check if account has enough balance to pay the fee
        if (account.balance < tx.fee) {
            return .tec_claim;
        }

        // Validate sequence number
        if (tx.sequence != account.sequence) {
            return .ter_retry;
        }

        // Transaction-specific validation would go here
        switch (tx.tx_type) {
            .payment => {
                // Validate payment-specific fields
            },
            .account_set => {
                // Validate account_set fields
            },
            else => {
                // Other transaction types
            },
        }

        return .tes_success;
    }

    /// Submit a transaction to the pending queue
    pub fn submitTransaction(self: *TransactionProcessor, tx: types.Transaction) !void {
        try self.pending_transactions.append(tx);
        std.debug.print("Transaction submitted: type={s}, fee={d}\n", .{
            @tagName(tx.tx_type),
            tx.fee,
        });
    }

    /// Get pending transactions for the next ledger
    pub fn getPendingTransactions(self: *const TransactionProcessor) []const types.Transaction {
        return self.pending_transactions.items;
    }

    /// Clear pending transactions (after ledger close)
    pub fn clearPending(self: *TransactionProcessor) void {
        self.pending_transactions.clearRetainingCapacity();
    }
};

/// Payment transaction (most common transaction type)
pub const PaymentTransaction = struct {
    base: types.Transaction,
    destination: types.AccountID,
    amount: types.Amount,
    destination_tag: ?u32 = null,
    send_max: ?types.Amount = null,

    /// Create a new payment transaction
    pub fn create(
        account: types.AccountID,
        destination: types.AccountID,
        amount: types.Amount,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) PaymentTransaction {
        return PaymentTransaction{
            .base = types.Transaction{
                .tx_type = .payment,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .destination = destination,
            .amount = amount,
        };
    }

    /// Sign the payment transaction
    pub fn sign(self: *PaymentTransaction, key_pair: crypto.KeyPair, allocator: std.mem.Allocator) !void {
        // Serialize the transaction for signing
        const tx_data = try self.serialize(allocator);
        defer allocator.free(tx_data);

        // Sign canonical transaction bytes using the XRPL signing domain.
        const signature = try key_pair.signXrplTransaction(tx_data, allocator);
        self.base.txn_signature = signature;
    }

    /// Serialize transaction for signing or transmission
    pub fn serialize(self: *const PaymentTransaction, allocator: std.mem.Allocator) ![]u8 {
        var serializer = try canonical.CanonicalSerializer.init(allocator);
        defer serializer.deinit();

        try serializeBaseFields(&serializer, &self.base);
        try serializer.addAccountID(3, self.destination);
        try serializeAmountField(&serializer, 1, self.amount);

        if (self.destination_tag) |destination_tag| {
            try serializer.addUInt32(14, destination_tag);
        }

        return serializer.finish();
    }
};

/// Account Set transaction - modify account settings
pub const AccountSetTransaction = struct {
    base: types.Transaction,
    clear_flag: ?u32 = null,
    set_flag: ?u32 = null,
    transfer_rate: ?u32 = null,
    email_hash: ?[16]u8 = null,

    pub fn create(
        account: types.AccountID,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) AccountSetTransaction {
        return AccountSetTransaction{
            .base = types.Transaction{
                .tx_type = .account_set,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
        };
    }

    pub fn serialize(self: *const AccountSetTransaction, allocator: std.mem.Allocator) ![]u8 {
        var serializer = try canonical.CanonicalSerializer.init(allocator);
        defer serializer.deinit();

        try serializeBaseFields(&serializer, &self.base);

        if (self.set_flag) |set_flag| {
            try serializer.addUInt32(5, set_flag);
        }
        if (self.clear_flag) |clear_flag| {
            try serializer.addUInt32(6, clear_flag);
        }
        if (self.transfer_rate) |transfer_rate| {
            try serializer.addUInt32(11, transfer_rate);
        }
        if (self.email_hash != null) {
            return error.UnsupportedFieldEncoding;
        }

        return serializer.finish();
    }
};

/// Trust Set transaction - create or modify a trust line
pub const TrustSetTransaction = struct {
    base: types.Transaction,
    limit_amount: types.Amount,
    quality_in: ?u32 = null,
    quality_out: ?u32 = null,

    pub fn create(
        account: types.AccountID,
        limit_amount: types.Amount,
        fee: types.Drops,
        sequence: u32,
        signing_pub_key: [33]u8,
    ) TrustSetTransaction {
        return TrustSetTransaction{
            .base = types.Transaction{
                .tx_type = .trust_set,
                .account = account,
                .fee = fee,
                .sequence = sequence,
                .signing_pub_key = signing_pub_key,
            },
            .limit_amount = limit_amount,
        };
    }
};

fn amountIsPositive(amount: types.Amount) bool {
    return switch (amount) {
        .xrp => |drops| drops > 0,
        .iou => |iou| iou.value > 0,
    };
}

/// OfferCreate transaction - create a DEX offer.
pub const OfferCreateTransaction = struct {
    base: types.Transaction,
    taker_gets: types.Amount,
    taker_pays: types.Amount,
    expiration: ?u32 = null,

    pub fn create(
        account: types.AccountID,
        taker_gets: types.Amount,
        taker_pays: types.Amount,
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
            .taker_gets = taker_gets,
            .taker_pays = taker_pays,
        };
    }

    pub fn validate(self: *const OfferCreateTransaction) !void {
        if (!amountIsPositive(self.taker_gets)) return error.InvalidTakerGets;
        if (!amountIsPositive(self.taker_pays)) return error.InvalidTakerPays;
    }

    pub fn serialize(self: *const OfferCreateTransaction, allocator: std.mem.Allocator) ![]u8 {
        var serializer = try canonical.CanonicalSerializer.init(allocator);
        defer serializer.deinit();

        try serializeBaseFields(&serializer, &self.base);
        try serializeAmountField(&serializer, 1, self.taker_gets);
        try serializeAmountField(&serializer, 2, self.taker_pays);

        if (self.expiration) |expiration| {
            try serializer.addUInt32(10, expiration);
        }

        return serializer.finish();
    }
};

/// OfferCancel transaction - cancel an existing DEX offer.
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

    pub fn validate(self: *const OfferCancelTransaction) !void {
        if (self.offer_sequence == 0) return error.InvalidOfferSequence;
    }

    pub fn serialize(self: *const OfferCancelTransaction, allocator: std.mem.Allocator) ![]u8 {
        var serializer = try canonical.CanonicalSerializer.init(allocator);
        defer serializer.deinit();

        try serializeBaseFields(&serializer, &self.base);
        try serializer.addUInt32(9, self.offer_sequence);
        return serializer.finish();
    }
};

test "transaction validation" {
    const allocator = std.testing.allocator;
    var processor = try TransactionProcessor.init(allocator);
    defer processor.deinit();

    var state = ledger.AccountState.init(allocator);
    defer state.deinit();

    // Create an account
    const account_id = [_]u8{1} ** 20;
    const account = types.AccountRoot{
        .account = account_id,
        .balance = 1000 * types.XRP,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = 1,
    };
    try state.putAccount(account);

    // Create a valid transaction
    const tx = types.Transaction{
        .tx_type = .payment,
        .account = account_id,
        .fee = types.MIN_TX_FEE,
        .sequence = 1,
        .signing_pub_key = [_]u8{0} ** 33,
    };

    const result = try processor.validateTransaction(&tx, &state);
    try std.testing.expectEqual(types.TransactionResult.tes_success, result);
}

test "payment transaction creation" {
    const sender = [_]u8{1} ** 20;
    const receiver = [_]u8{2} ** 20;
    const amount = types.Amount.fromXRP(100 * types.XRP);

    const payment = PaymentTransaction.create(
        sender,
        receiver,
        amount,
        types.MIN_TX_FEE,
        1,
        [_]u8{0} ** 33,
    );

    try std.testing.expectEqual(types.TransactionType.payment, payment.base.tx_type);
    try std.testing.expectEqual(amount, payment.amount);
}

test "payment transaction serialization is canonical" {
    const allocator = std.testing.allocator;
    var payment = PaymentTransaction.create(
        [_]u8{0x01} ** 20,
        [_]u8{0x02} ** 20,
        types.Amount.fromXRP(100),
        10,
        1,
        [_]u8{0x03} ** 33,
    );
    payment.destination_tag = 7;

    const serialized = try payment.serialize(allocator);
    defer allocator.free(serialized);

    try expectSerializedHex(
        serialized,
        "12000024000000012e0000000761400000000000006468400000000000000a8114010101010101010101010101010101010101010183140202020202020202020202020202020202020202",
    );
}

test "account set serialization is canonical" {
    const allocator = std.testing.allocator;
    var tx = AccountSetTransaction.create(
        [_]u8{0x03} ** 20,
        10,
        2,
        [_]u8{0x04} ** 33,
    );
    tx.set_flag = 2;
    tx.clear_flag = 1;
    tx.transfer_rate = 7;

    const serialized = try tx.serialize(allocator);
    defer allocator.free(serialized);

    try expectSerializedHex(
        serialized,
        "1200032400000002250000000226000000012b0000000768400000000000000a81140303030303030303030303030303030303030303",
    );
}

test "offer create transaction validation" {
    const account = [_]u8{1} ** 20;
    const gets = types.Amount.fromXRP(100 * types.XRP);
    const pays = types.Amount.fromXRP(200 * types.XRP);

    const tx = OfferCreateTransaction.create(
        account,
        gets,
        pays,
        types.MIN_TX_FEE,
        10,
        [_]u8{0} ** 33,
    );
    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.offer_create, tx.base.tx_type);
}

test "offer create serialization is canonical" {
    const allocator = std.testing.allocator;
    var tx = OfferCreateTransaction.create(
        [_]u8{0x04} ** 20,
        types.Amount.fromXRP(200),
        types.Amount.fromXRP(300),
        10,
        3,
        [_]u8{0x05} ** 33,
    );
    tx.expiration = 9;

    const serialized = try tx.serialize(allocator);
    defer allocator.free(serialized);

    try expectSerializedHex(
        serialized,
        "12000724000000032a000000096140000000000000c862400000000000012c68400000000000000a81140404040404040404040404040404040404040404",
    );
}

test "offer cancel transaction validation" {
    const account = [_]u8{1} ** 20;
    const tx = OfferCancelTransaction.create(
        account,
        55,
        types.MIN_TX_FEE,
        11,
        [_]u8{0} ** 33,
    );
    try tx.validate();
    try std.testing.expectEqual(types.TransactionType.offer_cancel, tx.base.tx_type);
}

test "offer cancel serialization is canonical" {
    const allocator = std.testing.allocator;
    const tx = OfferCancelTransaction.create(
        [_]u8{0x05} ** 20,
        55,
        10,
        4,
        [_]u8{0x06} ** 33,
    );

    const serialized = try tx.serialize(allocator);
    defer allocator.free(serialized);

    try expectSerializedHex(
        serialized,
        "1200082400000004290000003768400000000000000a81140505050505050505050505050505050505050505",
    );
}
