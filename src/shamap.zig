const std = @import("std");
const crypto = @import("crypto.zig");

/// SHAMap — the core XRPL radix-tree data structure.
///
/// Keys are 256-bit (32 bytes), typically transaction hashes or account IDs.
/// The tree is indexed by the key's nibbles (4 bits each), giving 16 children
/// per inner node.  Inner nodes hash their children using SHA-512 Half, and
/// leaf nodes store key-value pairs.  The root hash uniquely identifies the
/// entire tree state.
pub const SHAMap = struct {
    allocator: std.mem.Allocator,
    root: ?*Node,

    // XRPL hash-tree prefixes (network byte order).
    // Leaf:  "MLN\0"  (0x4D4C4E00)
    // Inner: "MIN\0"  (0x4D494E00)
    pub const LEAF_PREFIX = [_]u8{ 0x4D, 0x4C, 0x4E, 0x00 };
    pub const INNER_PREFIX = [_]u8{ 0x4D, 0x49, 0x4E, 0x00 };

    pub const Node = union(enum) {
        inner: InnerNode,
        leaf: LeafNode,
    };

    pub const InnerNode = struct {
        children: [16]?*Node,
        hash: ?[32]u8, // cached; invalidated on mutation

        fn empty() InnerNode {
            return .{
                .children = [_]?*Node{null} ** 16,
                .hash = null,
            };
        }
    };

    pub const LeafNode = struct {
        key: [32]u8,
        value: []const u8, // owned copy
        hash: [32]u8,
    };

    /// A single step in a Merkle inclusion proof.
    pub const ProofNode = struct {
        siblings: [15][32]u8, // hashes of the 15 sibling branches at this level
        nibble: u4, // which branch was descended into
    };

    // ── Helpers ──────────────────────────────────────────────────────────

    const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;

    /// Extract nibble `idx` from a 32-byte key (high nibble first).
    fn getNibble(key: [32]u8, idx: usize) u4 {
        const byte = key[idx / 2];
        return if (idx % 2 == 0)
            @truncate(byte >> 4)
        else
            @truncate(byte & 0x0F);
    }

    /// Compute the hash of a leaf: SHA-512-Half(LEAF_PREFIX || key || value).
    fn computeLeafHash(key: [32]u8, value: []const u8) [32]u8 {
        var buf: [4 + 32 + 65536]u8 = undefined; // stack fast-path
        if (value.len <= 65536) {
            @memcpy(buf[0..4], &LEAF_PREFIX);
            @memcpy(buf[4..36], &key);
            @memcpy(buf[36 .. 36 + value.len], value);
            return crypto.Hash.sha512Half(buf[0 .. 36 + value.len]);
        }
        // Fallback: use Sha512 streaming
        var h = std.crypto.hash.sha2.Sha512.init(.{});
        h.update(&LEAF_PREFIX);
        h.update(&key);
        h.update(value);
        var full: [64]u8 = undefined;
        h.final(&full);
        var result: [32]u8 = undefined;
        @memcpy(&result, full[0..32]);
        return result;
    }

    /// Compute the hash of an inner node:
    /// SHA-512-Half(INNER_PREFIX || child_0_hash || ... || child_15_hash)
    fn computeInnerHash(self: *SHAMap, inner: *InnerNode) [32]u8 {
        var buf: [4 + 16 * 32]u8 = undefined;
        @memcpy(buf[0..4], &INNER_PREFIX);
        for (inner.children, 0..) |maybe_child, i| {
            const child_hash = if (maybe_child) |child| switch (child.*) {
                .inner => |*inn| blk: {
                    if (inn.hash == null) {
                        inn.hash = self.computeInnerHash(inn);
                    }
                    break :blk inn.hash.?;
                },
                .leaf => |lf| lf.hash,
            } else ZERO_HASH;
            @memcpy(buf[4 + i * 32 .. 4 + (i + 1) * 32], &child_hash);
        }
        return crypto.Hash.sha512Half(&buf);
    }

    fn allocNode(self: *SHAMap, value: Node) !*Node {
        const node = try self.allocator.create(Node);
        node.* = value;
        return node;
    }

    fn freeNode(self: *SHAMap, node: *Node) void {
        switch (node.*) {
            .inner => |*inner| {
                for (&inner.children) |*child_slot| {
                    if (child_slot.*) |child| {
                        self.freeNode(child);
                        child_slot.* = null;
                    }
                }
            },
            .leaf => |lf| {
                self.allocator.free(lf.value);
            },
        }
        self.allocator.destroy(node);
    }

    /// Invalidate cached hashes from root down to `depth` along `key`.
    fn invalidatePath(self: *SHAMap, key: [32]u8, depth: usize) void {
        var current: ?*Node = self.root;
        var d: usize = 0;
        while (d < depth) : (d += 1) {
            const c = current orelse return;
            switch (c.*) {
                .inner => |*inner| {
                    inner.hash = null;
                    const nibble = getNibble(key, d);
                    current = inner.children[nibble];
                },
                .leaf => return,
            }
        }
        // Also invalidate the node at `depth` if it is inner.
        if (current) |c| {
            switch (c.*) {
                .inner => |*inner| inner.hash = null,
                .leaf => {},
            }
        }
    }

    // ── Public API ───────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator) SHAMap {
        return .{
            .allocator = allocator,
            .root = null,
        };
    }

    pub fn deinit(self: *SHAMap) void {
        if (self.root) |root| {
            self.freeNode(root);
            self.root = null;
        }
    }

    /// Insert a key-value pair.  If the key already exists its value is replaced.
    pub fn insert(self: *SHAMap, key: [32]u8, value: []const u8) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        self.root = try self.insertRecursive(self.root, key, owned_value, 0);
    }

    fn insertRecursive(self: *SHAMap, maybe_node: ?*Node, key: [32]u8, owned_value: []const u8, depth: usize) !*Node {
        if (depth >= 64) return error.MaxDepthExceeded;

        const node = maybe_node orelse {
            // Empty slot — create leaf.
            return self.allocNode(.{ .leaf = .{
                .key = key,
                .value = owned_value,
                .hash = computeLeafHash(key, owned_value),
            } });
        };

        switch (node.*) {
            .leaf => |existing| {
                if (std.mem.eql(u8, &existing.key, &key)) {
                    // Replace value.
                    self.allocator.free(existing.value);
                    node.*.leaf.value = owned_value;
                    node.*.leaf.hash = computeLeafHash(key, owned_value);
                    return node;
                }
                // Split: create inner node, re-insert both leaves.
                const old_nibble = getNibble(existing.key, depth);
                const new_nibble = getNibble(key, depth);

                const inner = try self.allocNode(.{ .inner = InnerNode.empty() });

                if (old_nibble != new_nibble) {
                    inner.inner.children[old_nibble] = node; // reuse existing leaf node
                    const new_leaf = try self.allocNode(.{ .leaf = .{
                        .key = key,
                        .value = owned_value,
                        .hash = computeLeafHash(key, owned_value),
                    } });
                    inner.inner.children[new_nibble] = new_leaf;
                } else {
                    // Same nibble — create child inner and recurse.
                    const child = try self.insertRecursive(node, key, owned_value, depth + 1);
                    inner.inner.children[old_nibble] = child;
                }
                return inner;
            },
            .inner => |*inner| {
                inner.hash = null; // invalidate cache
                const nibble = getNibble(key, depth);
                inner.children[nibble] = try self.insertRecursive(inner.children[nibble], key, owned_value, depth + 1);
                return node;
            },
        }
    }

    /// Look up a value by key.
    pub fn get(self: *const SHAMap, key: [32]u8) ?[]const u8 {
        var current: ?*const Node = if (self.root) |r| r else return null;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            const node = current orelse return null;
            switch (node.*) {
                .leaf => |lf| {
                    return if (std.mem.eql(u8, &lf.key, &key)) lf.value else null;
                },
                .inner => |inner| {
                    const nibble = getNibble(key, depth);
                    current = inner.children[nibble];
                },
            }
        }
        return null;
    }

    /// Remove a key.  Returns true if the key was found and removed.
    pub fn remove(self: *SHAMap, key: [32]u8) !bool {
        if (self.root == null) return false;
        return self.removeRecursive(&self.root, key, 0);
    }

    fn removeRecursive(self: *SHAMap, slot: *?*Node, key: [32]u8, depth: usize) !bool {
        const node = slot.* orelse return false;
        switch (node.*) {
            .leaf => |lf| {
                if (!std.mem.eql(u8, &lf.key, &key)) return false;
                self.freeNode(node);
                slot.* = null;
                return true;
            },
            .inner => |*inner| {
                const nibble = getNibble(key, depth);
                const removed = try self.removeRecursive(&inner.children[nibble], key, depth + 1);
                if (!removed) return false;
                inner.hash = null; // invalidate

                // Collapse: if only one child remains and it is a leaf, pull it up.
                var sole_child: ?*Node = null;
                var child_count: usize = 0;
                for (inner.children) |ch| {
                    if (ch != null) {
                        child_count += 1;
                        sole_child = ch;
                    }
                }
                if (child_count == 1) {
                    if (sole_child) |sc| {
                        switch (sc.*) {
                            .leaf => {
                                // Pull the leaf up, replace this inner node.
                                const leaf_copy = sc.*;
                                self.allocator.destroy(sc);
                                node.* = leaf_copy;
                            },
                            .inner => {},
                        }
                    }
                } else if (child_count == 0) {
                    self.allocator.destroy(node);
                    slot.* = null;
                }
                return true;
            },
        }
    }

    /// Compute the root hash of the tree.
    pub fn rootHash(self: *SHAMap) [32]u8 {
        const root = self.root orelse {
            // Empty tree: hash of an inner node with 16 zero children.
            var buf: [4 + 16 * 32]u8 = undefined;
            @memcpy(buf[0..4], &INNER_PREFIX);
            @memset(buf[4..], 0);
            return crypto.Hash.sha512Half(&buf);
        };
        switch (root.*) {
            .inner => |*inner| {
                if (inner.hash == null) {
                    inner.hash = self.computeInnerHash(inner);
                }
                return inner.hash.?;
            },
            .leaf => |lf| return lf.hash,
        }
    }

    /// Generate a Merkle inclusion proof for a key.
    pub fn getProof(self: *SHAMap, key: [32]u8) !?[]ProofNode {
        var proof = std.ArrayList(ProofNode).init(self.allocator);
        errdefer proof.deinit();

        var current: ?*Node = self.root;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            const node = current orelse {
                proof.deinit();
                return null; // key not in tree
            };
            switch (node.*) {
                .leaf => |lf| {
                    if (std.mem.eql(u8, &lf.key, &key)) {
                        return try proof.toOwnedSlice();
                    }
                    proof.deinit();
                    return null;
                },
                .inner => |*inner| {
                    const nibble = getNibble(key, depth);
                    var pn: ProofNode = .{
                        .siblings = undefined,
                        .nibble = nibble,
                    };
                    // Collect sibling hashes.
                    var sib_idx: usize = 0;
                    for (0..16) |i| {
                        if (i == nibble) continue;
                        const child_hash: [32]u8 = if (inner.children[i]) |child| switch (child.*) {
                            .inner => |*inn| blk: {
                                if (inn.hash == null) inn.hash = self.computeInnerHash(inn);
                                break :blk inn.hash.?;
                            },
                            .leaf => |lf| lf.hash,
                        } else ZERO_HASH;
                        pn.siblings[sib_idx] = child_hash;
                        sib_idx += 1;
                    }
                    try proof.append(pn);
                    current = inner.children[nibble];
                },
            }
        }
        proof.deinit();
        return null;
    }

    /// Verify a Merkle inclusion proof.
    pub fn verifyProof(
        expected_root: [32]u8,
        key: [32]u8,
        value: []const u8,
        proof: []const ProofNode,
    ) bool {
        // Start from the leaf hash and reconstruct upward.
        var current_hash = computeLeafHash(key, value);

        // Walk proof bottom-up (reverse order).
        var i: usize = proof.len;
        while (i > 0) {
            i -= 1;
            const pn = proof[i];
            var buf: [4 + 16 * 32]u8 = undefined;
            @memcpy(buf[0..4], &INNER_PREFIX);

            // Reconstruct all 16 child hashes.
            var sib_idx: usize = 0;
            for (0..16) |c| {
                const h: [32]u8 = if (c == pn.nibble)
                    current_hash
                else blk: {
                    const s = pn.siblings[sib_idx];
                    sib_idx += 1;
                    break :blk s;
                };
                @memcpy(buf[4 + c * 32 .. 4 + (c + 1) * 32], &h);
            }
            current_hash = crypto.Hash.sha512Half(&buf);
        }
        return std.mem.eql(u8, &current_hash, &expected_root);
    }
};

// ==========================================================================
// Tests
// ==========================================================================

test "shamap: insert and retrieve values" {
    const allocator = std.testing.allocator;
    var map = SHAMap.init(allocator);
    defer map.deinit();

    var key1: [32]u8 = [_]u8{0} ** 32;
    key1[0] = 0xAB;
    const val1 = "hello";
    try map.insert(key1, val1);
    const got = map.get(key1);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(val1, got.?);

    // Second key
    var key2: [32]u8 = [_]u8{0} ** 32;
    key2[0] = 0xCD;
    try map.insert(key2, "world");
    try std.testing.expectEqualStrings("world", map.get(key2).?);
    // First key still present
    try std.testing.expectEqualStrings("hello", map.get(key1).?);

    // Missing key
    const key3: [32]u8 = [_]u8{0xFF} ** 32;
    try std.testing.expect(map.get(key3) == null);
}

test "shamap: root hash changes on mutation" {
    const allocator = std.testing.allocator;
    var map = SHAMap.init(allocator);
    defer map.deinit();

    const h0 = map.rootHash();

    var key1: [32]u8 = [_]u8{0} ** 32;
    key1[0] = 0x01;
    try map.insert(key1, "a");
    const h1 = map.rootHash();
    try std.testing.expect(!std.mem.eql(u8, &h0, &h1));

    var key2: [32]u8 = [_]u8{0} ** 32;
    key2[0] = 0x02;
    try map.insert(key2, "b");
    const h2 = map.rootHash();
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "shamap: empty tree has deterministic root hash" {
    const allocator = std.testing.allocator;
    var map1 = SHAMap.init(allocator);
    defer map1.deinit();
    var map2 = SHAMap.init(allocator);
    defer map2.deinit();

    const h1 = map1.rootHash();
    const h2 = map2.rootHash();
    try std.testing.expectEqualSlices(u8, &h1, &h2);

    // The empty root is SHA-512-Half(INNER_PREFIX || 0*512)
    var buf: [4 + 16 * 32]u8 = undefined;
    @memcpy(buf[0..4], &SHAMap.INNER_PREFIX);
    @memset(buf[4..], 0);
    const expected = crypto.Hash.sha512Half(&buf);
    try std.testing.expectEqualSlices(u8, &expected, &h1);
}

test "shamap: proof generation and verification" {
    const allocator = std.testing.allocator;
    var map = SHAMap.init(allocator);
    defer map.deinit();

    var key1: [32]u8 = [_]u8{0} ** 32;
    key1[0] = 0xAA;
    try map.insert(key1, "val1");

    var key2: [32]u8 = [_]u8{0} ** 32;
    key2[0] = 0xBB;
    try map.insert(key2, "val2");

    var key3: [32]u8 = [_]u8{0} ** 32;
    key3[0] = 0xCC;
    try map.insert(key3, "val3");

    const root = map.rootHash();

    // Proof for key1
    const maybe_proof = try map.getProof(key1);
    try std.testing.expect(maybe_proof != null);
    const proof = maybe_proof.?;
    defer allocator.free(proof);
    try std.testing.expect(SHAMap.verifyProof(root, key1, "val1", proof));

    // Wrong value should fail
    try std.testing.expect(!SHAMap.verifyProof(root, key1, "wrong", proof));

    // Proof for missing key returns null
    const missing: [32]u8 = [_]u8{0xFF} ** 32;
    try std.testing.expect((try map.getProof(missing)) == null);
}

test "shamap: deterministic — insertion order does not matter" {
    const allocator = std.testing.allocator;

    var keys: [5][32]u8 = undefined;
    const values = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    for (0..5) |i| {
        keys[i] = [_]u8{0} ** 32;
        keys[i][0] = @truncate(i * 47 + 13); // spread across nibble space
        keys[i][1] = @truncate(i * 31 + 7);
    }

    // Forward order
    var map1 = SHAMap.init(allocator);
    defer map1.deinit();
    for (0..5) |i| try map1.insert(keys[i], values[i]);
    const h1 = map1.rootHash();

    // Reverse order
    var map2 = SHAMap.init(allocator);
    defer map2.deinit();
    var ri: usize = 5;
    while (ri > 0) {
        ri -= 1;
        try map2.insert(keys[ri], values[ri]);
    }
    const h2 = map2.rootHash();

    try std.testing.expectEqualSlices(u8, &h1, &h2);

    // Interleaved order: 2, 4, 0, 3, 1
    const order = [_]usize{ 2, 4, 0, 3, 1 };
    var map3 = SHAMap.init(allocator);
    defer map3.deinit();
    for (order) |i| try map3.insert(keys[i], values[i]);
    const h3 = map3.rootHash();

    try std.testing.expectEqualSlices(u8, &h1, &h3);
}

test "shamap: remove key" {
    const allocator = std.testing.allocator;
    var map = SHAMap.init(allocator);
    defer map.deinit();

    var key1: [32]u8 = [_]u8{0} ** 32;
    key1[0] = 0x10;
    try map.insert(key1, "x");

    var key2: [32]u8 = [_]u8{0} ** 32;
    key2[0] = 0x20;
    try map.insert(key2, "y");

    const before = map.rootHash();
    const removed = try map.remove(key1);
    try std.testing.expect(removed);
    try std.testing.expect(map.get(key1) == null);
    try std.testing.expectEqualStrings("y", map.get(key2).?);

    const after = map.rootHash();
    try std.testing.expect(!std.mem.eql(u8, &before, &after));

    // Removing non-existent key returns false
    try std.testing.expect(!(try map.remove(key1)));
}

test "shamap: replace value for existing key" {
    const allocator = std.testing.allocator;
    var map = SHAMap.init(allocator);
    defer map.deinit();

    var key: [32]u8 = [_]u8{0} ** 32;
    key[0] = 0x42;
    try map.insert(key, "original");
    const h1 = map.rootHash();

    try map.insert(key, "updated");
    try std.testing.expectEqualStrings("updated", map.get(key).?);
    const h2 = map.rootHash();
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "shamap: keys sharing nibble prefix" {
    const allocator = std.testing.allocator;
    var map = SHAMap.init(allocator);
    defer map.deinit();

    // Two keys that share the first nibble (0xA_)
    var key1: [32]u8 = [_]u8{0} ** 32;
    key1[0] = 0xA1;
    var key2: [32]u8 = [_]u8{0} ** 32;
    key2[0] = 0xA2;

    try map.insert(key1, "one");
    try map.insert(key2, "two");

    try std.testing.expectEqualStrings("one", map.get(key1).?);
    try std.testing.expectEqualStrings("two", map.get(key2).?);
}
