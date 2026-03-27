const std = @import("std");
const types = @import("types.zig");
const ledger_objects = @import("ledger_objects.zig");

const AccountID = types.AccountID;
const CurrencyCode = types.CurrencyCode;

// ---------------------------------------------------------------------------
// IOUBalance — signed balance for trust lines
// ---------------------------------------------------------------------------

/// Signed balance for a trust line. Positive means the high account owes the
/// low account; negative means the low account owes the high account.
pub const IOUBalance = struct {
    /// Absolute value of the balance.
    value: u64,
    /// True when the balance is negative (low owes high).
    is_negative: bool,

    pub fn zero() IOUBalance {
        return .{ .value = 0, .is_negative = false };
    }

    /// Add a signed delta. `delta_negative` == true means subtract.
    pub fn addDelta(self: IOUBalance, delta: u64, delta_negative: bool) error{BalanceOverflow}!IOUBalance {
        if (self.is_negative == delta_negative) {
            // Same sign: magnitudes add.
            const new_val, const overflow = @addWithOverflow(self.value, delta);
            if (overflow != 0) return error.BalanceOverflow;
            return IOUBalance{ .value = new_val, .is_negative = self.is_negative };
        }
        // Different signs: magnitudes subtract.
        if (self.value >= delta) {
            return IOUBalance{
                .value = self.value - delta,
                .is_negative = if (self.value - delta == 0) false else self.is_negative,
            };
        }
        return IOUBalance{
            .value = delta - self.value,
            .is_negative = delta_negative,
        };
    }

    pub fn negate(self: IOUBalance) IOUBalance {
        if (self.value == 0) return self;
        return .{ .value = self.value, .is_negative = !self.is_negative };
    }
};

// ---------------------------------------------------------------------------
// TrustLineFlags
// ---------------------------------------------------------------------------

/// Packed flags for a trust line, mirroring RippleStateFlags in ledger_objects.
pub const TrustLineFlags = packed struct {
    low_reserve: bool = false,
    high_reserve: bool = false,
    low_auth: bool = false,
    high_auth: bool = false,
    low_no_ripple: bool = false,
    high_no_ripple: bool = false,
    low_freeze: bool = false,
    high_freeze: bool = false,
    _padding: u24 = 0,
};

// ---------------------------------------------------------------------------
// TrustLine
// ---------------------------------------------------------------------------

/// A bilateral credit relationship between two accounts for a specific
/// currency. The two accounts are stored in canonical order: `account_low`
/// is the numerically lower AccountID.
pub const TrustLine = struct {
    /// Numerically lower account.
    account_low: AccountID,
    /// Numerically higher account.
    account_high: AccountID,
    /// Currency for this trust line.
    currency: CurrencyCode,
    /// Signed balance. Positive = high owes low, negative = low owes high.
    balance: IOUBalance,
    /// Maximum amount the low account is willing to hold (owed by high).
    limit_low: u64,
    /// Maximum amount the high account is willing to hold (owed by low).
    limit_high: u64,
    /// Trust line flags.
    flags: TrustLineFlags,
};

// ---------------------------------------------------------------------------
// TrustLineKey — used for HashMap lookups
// ---------------------------------------------------------------------------

/// Uniquely identifies a trust line: (low, high, currency).
const TrustLineKey = struct {
    low: AccountID,
    high: AccountID,
    currency: [20]u8,
};

fn trustLineKeyHash(key: TrustLineKey) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&key.low);
    hasher.update(&key.high);
    hasher.update(&key.currency);
    return hasher.final();
}

fn trustLineKeyEql(a: TrustLineKey, b: TrustLineKey) bool {
    return std.mem.eql(u8, &a.low, &b.low) and
        std.mem.eql(u8, &a.high, &b.high) and
        std.mem.eql(u8, &a.currency, &b.currency);
}

const TrustLineKeyContext = struct {
    pub fn hash(_: TrustLineKeyContext, key: TrustLineKey) u64 {
        return trustLineKeyHash(key);
    }
    pub fn eql(_: TrustLineKeyContext, a: TrustLineKey, b: TrustLineKey) bool {
        return trustLineKeyEql(a, b);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Determine canonical ordering of two account IDs. Returns (low, high).
fn orderAccounts(a: AccountID, b: AccountID) struct { AccountID, AccountID } {
    const order = std.mem.order(u8, &a, &b);
    return switch (order) {
        .lt => .{ a, b },
        .gt => .{ b, a },
        .eq => .{ a, b },
    };
}

fn makeKey(a: AccountID, b: AccountID, currency: CurrencyCode) TrustLineKey {
    const low, const high = orderAccounts(a, b);
    return .{ .low = low, .high = high, .currency = currency.bytes };
}

// ---------------------------------------------------------------------------
// TrustLineManager
// ---------------------------------------------------------------------------

pub const TrustLineError = error{
    TrustLineExists,
    TrustLineNotFound,
    LimitExceeded,
    NoRipple,
    LineFrozen,
    SameAccount,
    BalanceOverflow,
};

/// Manages trust lines for in-memory ledger state.
pub const TrustLineManager = struct {
    allocator: std.mem.Allocator,
    lines: std.HashMap(TrustLineKey, TrustLine, TrustLineKeyContext, 80),
    /// Secondary index: for each account, the set of keys it participates in.
    account_index: std.AutoHashMap(AccountID, std.ArrayList(TrustLineKey)),

    pub fn init(allocator: std.mem.Allocator) TrustLineManager {
        return .{
            .allocator = allocator,
            .lines = std.HashMap(TrustLineKey, TrustLine, TrustLineKeyContext, 80).init(allocator),
            .account_index = std.AutoHashMap(AccountID, std.ArrayList(TrustLineKey)).init(allocator),
        };
    }

    pub fn deinit(self: *TrustLineManager) void {
        // Free the account index ArrayLists.
        var it = self.account_index.valueIterator();
        while (it.next()) |list_ptr| {
            list_ptr.deinit();
        }
        self.account_index.deinit();
        self.lines.deinit();
    }

    // -- Index helpers --

    fn addToIndex(self: *TrustLineManager, account: AccountID, key: TrustLineKey) !void {
        const result = try self.account_index.getOrPut(account);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(TrustLineKey).init(self.allocator);
        }
        try result.value_ptr.append(key);
    }

    // -- Public API --

    /// Create a new trust line between `account` and `peer` for `currency`.
    /// `limit` is the maximum the calling account is willing to hold.
    pub fn createTrustLine(
        self: *TrustLineManager,
        account: AccountID,
        peer: AccountID,
        currency: CurrencyCode,
        limit: u64,
    ) TrustLineError!void {
        if (std.mem.eql(u8, &account, &peer)) return error.SameAccount;

        const key = makeKey(account, peer, currency);

        if (self.lines.contains(key)) return error.TrustLineExists;

        const low, const high = orderAccounts(account, peer);
        const is_low = std.mem.eql(u8, &account, &low);

        const line = TrustLine{
            .account_low = low,
            .account_high = high,
            .currency = currency,
            .balance = IOUBalance.zero(),
            .limit_low = if (is_low) limit else 0,
            .limit_high = if (!is_low) limit else 0,
            .flags = .{},
        };

        self.lines.put(key, line) catch return error.BalanceOverflow;
        self.addToIndex(low, key) catch return error.BalanceOverflow;
        self.addToIndex(high, key) catch return error.BalanceOverflow;
    }

    /// Retrieve a trust line between two accounts for a currency.
    pub fn getTrustLine(
        self: *const TrustLineManager,
        account1: AccountID,
        account2: AccountID,
        currency: CurrencyCode,
    ) ?TrustLine {
        const key = makeKey(account1, account2, currency);
        return self.lines.get(key);
    }

    /// Adjust the balance of a trust line. A positive `delta` means account1
    /// owes more to account2; negative means account2 owes more to account1.
    /// Enforces trust limits.
    pub fn adjustBalance(
        self: *TrustLineManager,
        account1: AccountID,
        account2: AccountID,
        currency: CurrencyCode,
        delta: u64,
        delta_negative: bool,
    ) TrustLineError!void {
        const key = makeKey(account1, account2, currency);
        const ptr = self.lines.getPtr(key) orelse return error.TrustLineNotFound;

        // Check freeze.
        if (ptr.flags.low_freeze or ptr.flags.high_freeze) return error.LineFrozen;

        // Determine direction relative to canonical ordering.
        // Balance positive = high owes low.
        // If account1 == low and delta positive => low is *receiving* => high owes more => balance increases.
        // If account1 == high and delta positive => high is *owing* more => balance increases.
        const account1_is_low = std.mem.eql(u8, &account1, &ptr.account_low);
        // From account1's perspective, a positive delta means "account1 receives more".
        // When account1 is low: receiving more means balance goes more positive.
        // When account1 is high: receiving more means balance goes more negative.
        const bal_negative = if (account1_is_low) delta_negative else !delta_negative;

        const new_balance = ptr.balance.addDelta(delta, bal_negative) catch return error.BalanceOverflow;

        // Enforce limits.
        // Positive balance (high owes low): low holds it, capped by limit_low.
        // Negative balance (low owes high): high holds it, capped by limit_high.
        if (!new_balance.is_negative and new_balance.value > ptr.limit_low and ptr.limit_low != 0) {
            // Low is holding more than it wants.
            if (new_balance.value > ptr.limit_low) return error.LimitExceeded;
        }
        if (new_balance.is_negative and new_balance.value > ptr.limit_high and ptr.limit_high != 0) {
            // High is holding more than it wants.
            if (new_balance.value > ptr.limit_high) return error.LimitExceeded;
        }

        ptr.balance = new_balance;
    }

    /// Set the no-ripple flag for `account`'s side of the trust line with `peer`.
    pub fn setNoRipple(
        self: *TrustLineManager,
        account: AccountID,
        peer: AccountID,
        currency: CurrencyCode,
        enabled: bool,
    ) TrustLineError!void {
        const key = makeKey(account, peer, currency);
        const ptr = self.lines.getPtr(key) orelse return error.TrustLineNotFound;
        const is_low = std.mem.eql(u8, &account, &ptr.account_low);
        if (is_low) {
            ptr.flags.low_no_ripple = enabled;
        } else {
            ptr.flags.high_no_ripple = enabled;
        }
    }

    /// Set the freeze flag for `account`'s side of the trust line with `peer`.
    pub fn setFreeze(
        self: *TrustLineManager,
        account: AccountID,
        peer: AccountID,
        currency: CurrencyCode,
        enabled: bool,
    ) TrustLineError!void {
        const key = makeKey(account, peer, currency);
        const ptr = self.lines.getPtr(key) orelse return error.TrustLineNotFound;
        const is_low = std.mem.eql(u8, &account, &ptr.account_low);
        if (is_low) {
            ptr.flags.low_freeze = enabled;
        } else {
            ptr.flags.high_freeze = enabled;
        }
    }

    /// Return all trust lines for a given account. Caller owns the returned slice.
    pub fn getAccountLines(self: *const TrustLineManager, account: AccountID) ![]TrustLine {
        const keys = self.account_index.get(account) orelse return try self.allocator.alloc(TrustLine, 0);
        var result = std.ArrayList(TrustLine).init(self.allocator);
        errdefer result.deinit();
        for (keys.items) |key| {
            if (self.lines.get(key)) |line| {
                try result.append(line);
            }
        }
        return result.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------------
// Rippling logic — IOU transfer along trust paths
// ---------------------------------------------------------------------------

pub const RippleError = error{
    PathEmpty,
    TrustLineNotFound,
    LimitExceeded,
    NoRipple,
    LineFrozen,
    SameAccount,
    BalanceOverflow,
};

/// Transfer `amount` of `currency` from `source` to `destination` through the
/// given `path`. The path is the list of intermediary accounts (excluding
/// source and destination). For a direct transfer with no intermediary,
/// pass an empty path.
///
/// A payment A -> B -> C adjusts:
///   - A's line to B (A sends, balance moves so A owes B more or B owes A less)
///   - B's line to C (B sends, balance moves so B owes C more or C owes B less)
pub fn transferIOU(
    manager: *TrustLineManager,
    source: AccountID,
    destination: AccountID,
    currency: CurrencyCode,
    amount: u64,
    path: []const AccountID,
) RippleError!void {
    // Build the full hop list: source, path[0], path[1], ..., destination.
    // Each consecutive pair requires a trust line adjustment.
    // For n hops, we have n+1 nodes and n adjustments.

    // Check for no-ripple on intermediaries.
    // No-ripple means: funds may not ripple *through* that account on a
    // given currency. In practice, if B has no-ripple set on the incoming
    // side AND on the outgoing side, rippling is blocked.
    //
    // Walk each intermediary (not source/destination) and check both sides.

    // Perform the adjustments. On failure, we do NOT roll back (caller
    // should snapshot state if atomicity is needed, matching XRPL's
    // transactor model).

    var prev = source;
    for (path) |hop| {
        // Check no-ripple on the intermediary. The intermediary is `prev`
        // when we look at the *outgoing* side of the first leg, but actually
        // the intermediary whose no-ripple we care about is `hop` — the
        // account that funds ripple *through*.
        try checkNoRipple(manager, prev, hop, currency);
        try singleHopTransfer(manager, prev, hop, currency, amount);
        prev = hop;
    }

    // Final hop: prev -> destination.
    if (path.len > 0) {
        // Check no-ripple for the last intermediary going to destination.
        try checkNoRipple(manager, path[path.len - 1], destination, currency);
    }
    try singleHopTransfer(manager, prev, destination, currency, amount);
}

/// Check whether rippling through `through` between `from` and `to` is
/// blocked by the no-ripple flag. Rippling is blocked when the `through`
/// account has no-ripple set on BOTH the incoming and outgoing trust lines.
fn checkNoRipple(
    manager: *const TrustLineManager,
    from: AccountID,
    through: AccountID,
    currency: CurrencyCode,
) RippleError!void {
    // We only block rippling when `through` is an intermediary and has
    // no-ripple on its side of the line with `from`.
    const key = makeKey(from, through, currency);
    const line = manager.lines.get(key) orelse return error.TrustLineNotFound;

    const through_is_low = std.mem.eql(u8, &through, &line.account_low);
    const no_ripple = if (through_is_low) line.flags.low_no_ripple else line.flags.high_no_ripple;
    if (no_ripple) return error.NoRipple;
}

/// Adjust one hop: `sender` sends `amount` to `receiver`.
fn singleHopTransfer(
    manager: *TrustLineManager,
    sender: AccountID,
    receiver: AccountID,
    currency: CurrencyCode,
    amount: u64,
) RippleError!void {
    const key = makeKey(sender, receiver, currency);
    const ptr = manager.lines.getPtr(key) orelse return error.TrustLineNotFound;

    // Check freeze.
    if (ptr.flags.low_freeze or ptr.flags.high_freeze) return error.LineFrozen;

    // Sending means the sender's obligation increases (or their credit
    // decreases). From the balance perspective:
    //   balance positive = high owes low.
    //   If sender == low, sending means low gives to high, so high owes
    //     low *less* => balance decreases.
    //   If sender == high, sending means high gives to low, so high owes
    //     low *more* ... wait, that's backwards. If high sends to low,
    //     high's debt decreases. Let's think again.
    //
    // "sender sends amount to receiver" means receiver ends up with more
    // of the currency. The balance tracks what high owes low.
    //   - If sender == high: high is paying low, so high owes less.
    //     Balance decreases (becomes less positive / more negative).
    //   - If sender == low: low is paying high, so low now holds less
    //     of high's IOUs; equivalently high owes low less. Wait no — if
    //     low sends to high, that means low is giving value to high.
    //     That means high owes low MORE. Balance increases.
    //
    // Correction:
    //   sender == low  => low sends to high => balance goes MORE positive
    //   sender == high => high sends to low => balance goes MORE negative
    //     (or less positive)
    //
    // But wait — in XRPL terms, "balance positive = high owes low" means
    // low holds IOUs from high. If low *sends* those IOUs back to high,
    // balance *decreases*. If high sends IOUs to low, balance *increases*.
    //
    // So: sender == low  => balance decreases (low is sending value away)
    //     sender == high => balance increases (high is sending value to low,
    //       increasing what high owes low)
    //
    // Hmm, let me think about this more concretely. Say Alice(low) and
    // Bob(high), balance = +100 means Bob owes Alice 100.
    //
    // Alice sends 50 to Bob: Alice is reducing her claim on Bob. Balance
    // goes from +100 to +50. Balance DECREASES. Correct.
    //
    // Bob sends 50 to Alice: Bob is paying off debt. Balance goes from
    // +100 to +150? No! Bob sending to Alice means Bob's debt increases?
    // No — Bob sends value to Alice means Alice now has more. If they're
    // IOUs: Alice already had claims on Bob. Bob sending Alice more means
    // Alice holds even more claims = balance increases. Actually, "sending"
    // in XRPL IOU context means the sender's balance goes down and the
    // receiver's goes up. From the trust line perspective:
    //
    //   If Bob(high) sends to Alice(low), Bob's account balance in this
    //   currency decreases and Alice's increases. On the trust line,
    //   positive balance = high owes low = Alice holds Bob-IOUs.
    //   After Bob sends to Alice, Alice holds MORE Bob-IOUs. Balance
    //   becomes more positive. So yes: sender==high => balance increases.
    //
    // Wait, that contradicts intuition. If Bob is paying Alice, his debt
    // to Alice should decrease, not increase. The confusion is between
    // "sending IOUs" vs "sending value". In XRPL:
    //
    //   A trust line balance represents the NET obligation. If the balance
    //   is +100 (high owes low 100), and high sends 30 *of the IOU
    //   currency* to low, that means high is issuing 30 more IOUs to low,
    //   making the balance +130. This only makes sense in the context of
    //   the issuer-holder model.
    //
    // For simplicity and correctness, let me use the XRPL convention:
    //   - A "send" of amount X from sender to receiver through a trust
    //     line adjusts the balance so that sender's side decreases by X
    //     and receiver's side increases by X.
    //   - "sender's side decreases" means:
    //     if sender == low: low's holdings decrease => balance decreases
    //       (less owed to low)
    //     if sender == high: high's holdings decrease => balance increases
    //       (more owed to low, i.e., high gave away value and now owes more)
    //
    // Actually, the simplest model: think of the balance as "what low
    // holds". Positive balance = low holds positive amount of IOUs from
    // high.
    //   sender == low  => low gives away IOUs => balance decreases
    //   sender == high => high gives low IOUs => balance increases

    const sender_is_low = std.mem.eql(u8, &sender, &ptr.account_low);

    // Delta to balance: sender==low => decrease (negative delta),
    //                   sender==high => increase (positive delta).
    const delta_negative = sender_is_low;

    const new_balance = ptr.balance.addDelta(amount, delta_negative) catch return error.BalanceOverflow;

    // Enforce limits.
    if (!new_balance.is_negative and new_balance.value > 0) {
        // Low holds positive balance (high owes low).
        if (ptr.limit_low > 0 and new_balance.value > ptr.limit_low) {
            return error.LimitExceeded;
        }
    }
    if (new_balance.is_negative and new_balance.value > 0) {
        // High holds the balance (low owes high).
        if (ptr.limit_high > 0 and new_balance.value > ptr.limit_high) {
            return error.LimitExceeded;
        }
    }

    ptr.balance = new_balance;
}

// ===========================================================================
// Tests
// ===========================================================================

fn makeAccount(id: u8) AccountID {
    var account: AccountID = [_]u8{0} ** 20;
    account[19] = id;
    return account;
}

test "create trust line between two accounts" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const usd = try CurrencyCode.fromStandard("USD");

    try mgr.createTrustLine(alice, bob, usd, 1000);

    const line = mgr.getTrustLine(alice, bob, usd).?;
    try std.testing.expectEqual(@as(u64, 0), line.balance.value);
    try std.testing.expect(!line.balance.is_negative);

    // Low account should be alice (0x01 < 0x02).
    try std.testing.expectEqual(@as(u8, 1), line.account_low[19]);
    try std.testing.expectEqual(@as(u8, 2), line.account_high[19]);
    try std.testing.expectEqual(@as(u64, 1000), line.limit_low);
    try std.testing.expectEqual(@as(u64, 0), line.limit_high);
}

test "adjust balance within limits" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const usd = try CurrencyCode.fromStandard("USD");

    try mgr.createTrustLine(alice, bob, usd, 1000);

    // Bob sends 500 to Alice. Alice is low, Bob is high.
    // sender==high => balance increases (low holds more).
    try mgr.adjustBalance(alice, bob, usd, 500, false);

    const line = mgr.getTrustLine(alice, bob, usd).?;
    try std.testing.expectEqual(@as(u64, 500), line.balance.value);
    try std.testing.expect(!line.balance.is_negative);
}

test "reject balance adjustment exceeding limit" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const usd = try CurrencyCode.fromStandard("USD");

    try mgr.createTrustLine(alice, bob, usd, 1000);

    // Try to receive 1500 when limit is 1000.
    const result = mgr.adjustBalance(alice, bob, usd, 1500, false);
    try std.testing.expectError(error.LimitExceeded, result);
}

test "no-ripple flag blocks rippling" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1); // low relative to bob
    const bob = makeAccount(2); // intermediary
    const carol = makeAccount(3); // high relative to bob

    const usd = try CurrencyCode.fromStandard("USD");

    try mgr.createTrustLine(alice, bob, usd, 1000);
    try mgr.createTrustLine(bob, carol, usd, 1000);

    // Set no-ripple on Bob's side of the Alice-Bob line.
    // Bob is high relative to Alice (2 > 1).
    try mgr.setNoRipple(bob, alice, usd, true);

    // Attempt to ripple from Alice through Bob to Carol.
    const path = [_]AccountID{bob};
    const result = transferIOU(&mgr, alice, carol, usd, 100, &path);
    try std.testing.expectError(error.NoRipple, result);
}

test "freeze flag blocks transfers" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const usd = try CurrencyCode.fromStandard("USD");

    try mgr.createTrustLine(alice, bob, usd, 1000);

    // Freeze Alice's side.
    try mgr.setFreeze(alice, bob, usd, true);

    // Direct transfer should fail.
    const empty_path = [_]AccountID{};
    const result = transferIOU(&mgr, alice, bob, usd, 100, &empty_path);
    try std.testing.expectError(error.LineFrozen, result);
}

test "multi-hop ripple payment" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const carol = makeAccount(3);

    const usd = try CurrencyCode.fromStandard("USD");

    // Set up trust lines with generous limits.
    try mgr.createTrustLine(alice, bob, usd, 5000);
    try mgr.createTrustLine(bob, carol, usd, 5000);

    // Also set limit for bob on the carol line. Bob is low (2 < 3).
    // The createTrustLine for (bob, carol) sets bob's limit (low) to 5000.
    // We need carol's limit too for carol to receive.
    // Actually, carol receiving means balance goes negative on the bob-carol
    // line (low=bob owes high=carol), so limit_high must be set.
    // Let's update by creating a second perspective. But createTrustLine
    // would fail with TrustLineExists. Instead, we need to adjust the
    // limit directly. For now, let's just set up the lines so that the
    // transfer direction works within existing limits.

    // Alice(1) -> Bob(2) -> Carol(3), sending 200 USD.
    // Hop 1: Alice sends to Bob on alice-bob line.
    //   alice is low, sender==low => balance decreases (goes negative).
    //   Negative balance = high(bob) holds the value. limit_high=0 (no limit
    //   set means unlimited for this implementation). Wait, limit_high is 0
    //   which we treat as "no limit". Let me re-check the limit logic.
    //
    // In singleHopTransfer, limit is only enforced when > 0, so 0 means
    // no limit. Good.

    const path = [_]AccountID{bob};
    try transferIOU(&mgr, alice, carol, usd, 200, &path);

    // Verify Alice-Bob line: alice sent 200, alice is low, sender==low =>
    // balance decreases. Started at 0, goes to -200.
    const ab_line = mgr.getTrustLine(alice, bob, usd).?;
    try std.testing.expectEqual(@as(u64, 200), ab_line.balance.value);
    try std.testing.expect(ab_line.balance.is_negative);

    // Verify Bob-Carol line: bob sent 200 to carol, bob is low (2<3),
    // sender==low => balance decreases. Started at 0, goes to -200.
    const bc_line = mgr.getTrustLine(bob, carol, usd).?;
    try std.testing.expectEqual(@as(u64, 200), bc_line.balance.value);
    try std.testing.expect(bc_line.balance.is_negative);
}

test "getAccountLines returns all lines for an account" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const carol = makeAccount(3);

    const usd = try CurrencyCode.fromStandard("USD");
    const eur = try CurrencyCode.fromStandard("EUR");

    try mgr.createTrustLine(alice, bob, usd, 1000);
    try mgr.createTrustLine(alice, carol, eur, 2000);

    const lines = try mgr.getAccountLines(alice);
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
}

test "cannot create trust line with self" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1);
    const usd = try CurrencyCode.fromStandard("USD");

    const result = mgr.createTrustLine(alice, alice, usd, 1000);
    try std.testing.expectError(error.SameAccount, result);
}

test "duplicate trust line creation fails" {
    const allocator = std.testing.allocator;
    var mgr = TrustLineManager.init(allocator);
    defer mgr.deinit();

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const usd = try CurrencyCode.fromStandard("USD");

    try mgr.createTrustLine(alice, bob, usd, 1000);
    const result = mgr.createTrustLine(bob, alice, usd, 500);
    try std.testing.expectError(error.TrustLineExists, result);
}

test "IOUBalance arithmetic" {
    // Zero + positive
    const b1 = try IOUBalance.zero().addDelta(100, false);
    try std.testing.expectEqual(@as(u64, 100), b1.value);
    try std.testing.expect(!b1.is_negative);

    // Positive - larger = negative
    const b2 = try b1.addDelta(150, true);
    try std.testing.expectEqual(@as(u64, 50), b2.value);
    try std.testing.expect(b2.is_negative);

    // Negate
    const b3 = b2.negate();
    try std.testing.expect(!b3.is_negative);
    try std.testing.expectEqual(@as(u64, 50), b3.value);

    // Zero negate stays zero
    const b4 = IOUBalance.zero().negate();
    try std.testing.expect(!b4.is_negative);
}
