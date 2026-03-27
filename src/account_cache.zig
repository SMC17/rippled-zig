const std = @import("std");
const types = @import("types.zig");
const lru_cache = @import("lru_cache.zig");

/// Default maximum number of accounts held in the cache.
pub const DEFAULT_CAPACITY: usize = 10_000;

/// A specialized LRU cache for XRPL account data.
///
/// Wraps `LRUCache(AccountID, AccountRoot)` with domain-specific methods
/// for looking up, storing, and invalidating account state.
pub const AccountCache = struct {
    const Inner = lru_cache.LRUCache(types.AccountID, types.AccountRoot);

    cache: Inner,

    /// Create an AccountCache with the given capacity (number of accounts).
    pub fn init(allocator: std.mem.Allocator, max_accounts: usize) AccountCache {
        return AccountCache{
            .cache = Inner.init(allocator, max_accounts),
        };
    }

    /// Create an AccountCache with the default capacity (10,000 accounts).
    pub fn initDefault(allocator: std.mem.Allocator) AccountCache {
        return init(allocator, DEFAULT_CAPACITY);
    }

    /// Free all resources.
    pub fn deinit(self: *AccountCache) void {
        self.cache.deinit();
    }

    /// Look up an account by its 20-byte AccountID.
    /// Returns the cached AccountRoot on hit, or null on miss.
    pub fn getAccount(self: *AccountCache, account_id: types.AccountID) ?types.AccountRoot {
        return self.cache.get(account_id);
    }

    /// Insert or update an account in the cache.
    pub fn putAccount(self: *AccountCache, account: types.AccountRoot) void {
        self.cache.put(account.account, account);
    }

    /// Remove an account from the cache (e.g., after a state change that
    /// invalidates the cached data). Returns true if the account was cached.
    pub fn invalidateAccount(self: *AccountCache, account_id: types.AccountID) bool {
        return self.cache.remove(account_id);
    }

    /// Return the number of accounts currently cached.
    pub fn count(self: *const AccountCache) usize {
        return self.cache.count();
    }

    /// Return the cache hit rate as a fraction in [0.0, 1.0].
    pub fn hitRate(self: *const AccountCache) f64 {
        return self.cache.hitRate();
    }

    /// Clear all cached accounts and reset stats.
    pub fn clear(self: *AccountCache) void {
        self.cache.clear();
    }
};

// ── Helpers for tests ──

fn makeAccountRoot(id_byte: u8, balance: types.Drops, seq: u32) types.AccountRoot {
    var account_id = [_]u8{0} ** 20;
    account_id[0] = id_byte;
    return types.AccountRoot{
        .account = account_id,
        .balance = balance,
        .flags = .{},
        .owner_count = 0,
        .previous_txn_id = [_]u8{0} ** 32,
        .previous_txn_lgr_seq = 1,
        .sequence = seq,
    };
}

// ── Tests ──

test "account cache put and get" {
    var cache = AccountCache.init(std.testing.allocator, 100);
    defer cache.deinit();

    const acct = makeAccountRoot(0x01, 1_000_000, 1);
    cache.putAccount(acct);

    const result = cache.getAccount(acct.account);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(acct.balance, result.?.balance);
    try std.testing.expectEqual(acct.sequence, result.?.sequence);
}

test "account cache invalidate" {
    var cache = AccountCache.init(std.testing.allocator, 100);
    defer cache.deinit();

    const acct = makeAccountRoot(0x02, 5_000_000, 10);
    cache.putAccount(acct);

    try std.testing.expect(cache.invalidateAccount(acct.account));
    try std.testing.expectEqual(@as(?types.AccountRoot, null), cache.getAccount(acct.account));
}

test "account cache eviction" {
    // Capacity of 2 -- inserting a third account evicts the LRU one.
    var cache = AccountCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    const a1 = makeAccountRoot(0x01, 100, 1);
    const a2 = makeAccountRoot(0x02, 200, 2);
    const a3 = makeAccountRoot(0x03, 300, 3);

    cache.putAccount(a1);
    cache.putAccount(a2);
    cache.putAccount(a3); // evicts a1

    try std.testing.expectEqual(@as(?types.AccountRoot, null), cache.getAccount(a1.account));
    try std.testing.expect(cache.getAccount(a2.account) != null);
    try std.testing.expect(cache.getAccount(a3.account) != null);
}

test "account cache hit rate" {
    var cache = AccountCache.init(std.testing.allocator, 100);
    defer cache.deinit();

    const acct = makeAccountRoot(0x01, 100, 1);
    cache.putAccount(acct);

    _ = cache.getAccount(acct.account); // hit
    _ = cache.getAccount(acct.account); // hit

    var missing_id = [_]u8{0} ** 20;
    missing_id[0] = 0xFF;
    _ = cache.getAccount(missing_id); // miss

    // 2 hits, 1 miss => ~0.667
    try std.testing.expectApproxEqAbs(@as(f64, 0.667), cache.hitRate(), 0.01);
}

test "account cache default capacity" {
    var cache = AccountCache.initDefault(std.testing.allocator);
    defer cache.deinit();

    const acct = makeAccountRoot(0x42, 999, 7);
    cache.putAccount(acct);
    try std.testing.expect(cache.getAccount(acct.account) != null);
}
