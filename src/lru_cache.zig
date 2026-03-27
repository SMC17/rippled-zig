const std = @import("std");

/// A generic LRU (Least Recently Used) cache with O(1) get, put, and evict.
///
/// Uses a doubly-linked list for recency ordering and a HashMap for key lookup.
/// When the cache reaches capacity, the least recently used entry is evicted.
pub fn LRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// A single cache entry stored in both the linked list and the hash map.
        pub const Node = struct {
            key: K,
            value: V,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        const Map = std.HashMap(K, *Node, HashContext(K), std.hash_map.default_max_load_percentage);

        allocator: std.mem.Allocator,
        map: Map,
        max_size: usize,

        // Doubly-linked list head (most recent) and tail (least recent)
        head: ?*Node = null,
        tail: ?*Node = null,

        // Stats
        hit_count: u64 = 0,
        miss_count: u64 = 0,

        /// Initialize a new LRU cache with the given maximum capacity.
        pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
            return Self{
                .allocator = allocator,
                .map = Map.init(allocator),
                .max_size = max_size,
            };
        }

        /// Free all resources owned by the cache.
        pub fn deinit(self: *Self) void {
            // Walk the linked list and free all nodes
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.map.deinit();
            self.head = null;
            self.tail = null;
        }

        /// Look up a key in the cache. On hit, moves the entry to the front
        /// (most recently used position). Returns null on miss.
        pub fn get(self: *Self, key: K) ?V {
            if (self.map.get(key)) |node| {
                self.hit_count += 1;
                self.moveToFront(node);
                return node.value;
            }
            self.miss_count += 1;
            return null;
        }

        /// Insert or update a key-value pair. If the cache is at capacity and
        /// the key is new, the least recently used entry is evicted first.
        pub fn put(self: *Self, key: K, value: V) void {
            if (self.map.get(key)) |node| {
                // Update existing entry
                node.value = value;
                self.moveToFront(node);
                return;
            }

            // Evict if at capacity
            if (self.map.count() >= self.max_size) {
                self.evictTail();
            }

            // Create new node
            const node = self.allocator.create(Node) catch return;
            node.* = Node{
                .key = key,
                .value = value,
            };

            // Insert into map
            self.map.put(key, node) catch {
                self.allocator.destroy(node);
                return;
            };

            // Push to front of list
            self.pushFront(node);
        }

        /// Remove a specific key from the cache. Returns true if the key was found.
        pub fn remove(self: *Self, key: K) bool {
            if (self.map.fetchRemove(key)) |kv| {
                const node = kv.value;
                self.detach(node);
                self.allocator.destroy(node);
                return true;
            }
            return false;
        }

        /// Return the number of entries currently in the cache.
        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        /// Return the hit rate as a fraction in [0.0, 1.0].
        /// Returns 0.0 if no lookups have been performed.
        pub fn hitRate(self: *const Self) f64 {
            const total = self.hit_count + self.miss_count;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hit_count)) / @as(f64, @floatFromInt(total));
        }

        /// Remove all entries and reset stats.
        pub fn clear(self: *Self) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.map.clearAndFree();
            self.head = null;
            self.tail = null;
            self.hit_count = 0;
            self.miss_count = 0;
        }

        // ── Internal linked-list operations ──

        /// Remove a node from the linked list without freeing it.
        fn detach(self: *Self, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                // node is head
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                // node is tail
                self.tail = node.prev;
            }

            node.prev = null;
            node.next = null;
        }

        /// Push a (detached) node to the front of the list.
        fn pushFront(self: *Self, node: *Node) void {
            node.prev = null;
            node.next = self.head;

            if (self.head) |old_head| {
                old_head.prev = node;
            }
            self.head = node;

            if (self.tail == null) {
                self.tail = node;
            }
        }

        /// Move an existing node to the front of the list.
        fn moveToFront(self: *Self, node: *Node) void {
            if (self.head == node) return; // already at front
            self.detach(node);
            self.pushFront(node);
        }

        /// Evict the tail (least recently used) node.
        fn evictTail(self: *Self) void {
            const tail_node = self.tail orelse return;
            _ = self.map.remove(tail_node.key);
            self.detach(tail_node);
            self.allocator.destroy(tail_node);
        }
    };
}

/// Generic hash context that works for byte-array keys and integer keys.
fn HashContext(comptime K: type) type {
    return struct {
        const Self = @This();

        pub fn hash(_: Self, key: K) u64 {
            if (comptime isFixedArray(K)) {
                return std.hash.Wyhash.hash(0, &key);
            } else if (@typeInfo(K) == .int or @typeInfo(K) == .comptime_int) {
                var buf: [@sizeOf(K)]u8 = undefined;
                std.mem.writeInt(K, &buf, key, .little);
                return std.hash.Wyhash.hash(0, &buf);
            } else {
                // Fallback: hash the raw bytes of the key
                return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
            }
        }

        pub fn eql(_: Self, a: K, b: K) bool {
            if (comptime isFixedArray(K)) {
                return std.mem.eql(u8, &a, &b);
            } else {
                return a == b;
            }
        }
    };
}

fn isFixedArray(comptime T: type) bool {
    return @typeInfo(T) == .array;
}

// ── Thread-safe wrapper ──

/// A thread-safe LRU cache that wraps LRUCache with a mutex.
pub fn ThreadSafeLRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Inner = LRUCache(K, V);

        inner: Inner,
        mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
            return Self{
                .inner = Inner.init(allocator, max_size),
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.inner.deinit();
        }

        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.inner.get(key);
        }

        pub fn put(self: *Self, key: K, value: V) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.inner.put(key, value);
        }

        pub fn remove(self: *Self, key: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.inner.remove(key);
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.inner.count();
        }

        pub fn hitRate(self: *Self) f64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.inner.hitRate();
        }

        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.inner.clear();
        }
    };
}

// ── Tests ──

test "insert and retrieve" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    cache.put(1, 100);
    cache.put(2, 200);
    cache.put(3, 300);

    try std.testing.expectEqual(@as(u32, 100), cache.get(1).?);
    try std.testing.expectEqual(@as(u32, 200), cache.get(2).?);
    try std.testing.expectEqual(@as(u32, 300), cache.get(3).?);
    try std.testing.expectEqual(@as(?u32, null), cache.get(99));
}

test "LRU eviction when full" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 3);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(2, 20);
    cache.put(3, 30);
    // Cache is full: [3, 2, 1]. Inserting 4 should evict 1.
    cache.put(4, 40);

    try std.testing.expectEqual(@as(?u32, null), cache.get(1)); // evicted
    try std.testing.expectEqual(@as(u32, 20), cache.get(2).?);
    try std.testing.expectEqual(@as(u32, 30), cache.get(3).?);
    try std.testing.expectEqual(@as(u32, 40), cache.get(4).?);
    try std.testing.expectEqual(@as(usize, 3), cache.count());
}

test "get moves item to front preventing eviction" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 3);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(2, 20);
    cache.put(3, 30);

    // Access key 1 to move it to front. Order becomes [1, 3, 2].
    _ = cache.get(1);

    // Insert key 4 -- should evict key 2 (now the LRU)
    cache.put(4, 40);

    try std.testing.expectEqual(@as(u32, 10), cache.get(1).?); // still present
    try std.testing.expectEqual(@as(?u32, null), cache.get(2)); // evicted
    try std.testing.expectEqual(@as(u32, 30), cache.get(3).?);
    try std.testing.expectEqual(@as(u32, 40), cache.get(4).?);
}

test "hit rate tracking" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(2, 20);

    _ = cache.get(1); // hit
    _ = cache.get(2); // hit
    _ = cache.get(3); // miss
    _ = cache.get(4); // miss

    try std.testing.expectEqual(@as(u64, 2), cache.hit_count);
    try std.testing.expectEqual(@as(u64, 2), cache.miss_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), cache.hitRate(), 0.001);
}

test "clear empties cache" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(2, 20);
    cache.put(3, 30);

    _ = cache.get(1); // generate some stats
    _ = cache.get(99); // miss

    cache.clear();

    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(u64, 0), cache.hit_count);
    try std.testing.expectEqual(@as(u64, 0), cache.miss_count);
    // Verify entries are gone (this will increment miss_count)
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(u64, 1), cache.miss_count);
}

test "remove specific key" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(2, 20);
    cache.put(3, 30);

    try std.testing.expect(cache.remove(2));
    try std.testing.expectEqual(@as(?u32, null), cache.get(2));
    try std.testing.expectEqual(@as(usize, 2), cache.count());

    // Removing a non-existent key returns false
    try std.testing.expect(!cache.remove(99));
}

test "cache with capacity 1" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 1);
    defer cache.deinit();

    cache.put(1, 10);
    try std.testing.expectEqual(@as(u32, 10), cache.get(1).?);

    // Inserting a second key evicts the first
    cache.put(2, 20);
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(u32, 20), cache.get(2).?);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
}

test "update existing key value" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(1, 99); // update

    try std.testing.expectEqual(@as(u32, 99), cache.get(1).?);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
}

test "byte array keys" {
    const KeyType = [20]u8;
    var cache = LRUCache(KeyType, u64).init(std.testing.allocator, 4);
    defer cache.deinit();

    var key1 = [_]u8{0} ** 20;
    key1[0] = 1;
    var key2 = [_]u8{0} ** 20;
    key2[0] = 2;

    cache.put(key1, 100);
    cache.put(key2, 200);

    try std.testing.expectEqual(@as(u64, 100), cache.get(key1).?);
    try std.testing.expectEqual(@as(u64, 200), cache.get(key2).?);
}

test "hitRate returns zero with no lookups" {
    var cache = LRUCache(u32, u32).init(std.testing.allocator, 4);
    defer cache.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cache.hitRate(), 0.001);
}
