const std = @import("std");
const types = @import("types.zig");

// ---------------------------------------------------------------------------
// PaymentPath — a sequence of steps from source to destination
// ---------------------------------------------------------------------------

/// A single step in a payment path: an (account, currency, issuer) triple.
/// Any field may be null if unchanged from the previous step.
pub const PathStep = struct {
    account: ?types.AccountID = null,
    currency: ?types.CurrencyCode = null,
    issuer: ?types.AccountID = null,

    /// Classify the step type.
    pub fn getType(self: PathStep) PathStepType {
        const has_account = self.account != null;
        const has_currency = self.currency != null;
        if (has_account and has_currency) return .account_currency;
        if (has_account) return .account;
        if (has_currency) return .currency;
        return .end;
    }
};

/// Path step type classification.
pub const PathStepType = enum {
    account,
    currency,
    account_currency,
    end,
};

/// A complete payment path with estimated cost metadata.
pub const PaymentPath = struct {
    steps: []PathStep,
    /// Estimated cost as a rational number (lower is better).
    /// For trust-line-only paths this is 0/1. For DEX crossings it
    /// reflects the best available offer quality.
    cost_num: u64 = 0,
    cost_den: u64 = 1,
    /// Number of hops (edges traversed).
    hop_count: u32 = 0,
    /// Estimated available liquidity (minimum along the path).
    liquidity: u64 = 0,

    /// Overall quality score used for ranking. Lower is better.
    /// Combines cost, path length, and inverse liquidity.
    pub fn score(self: PaymentPath) f64 {
        const cost: f64 = if (self.cost_den > 0)
            @as(f64, @floatFromInt(self.cost_num)) / @as(f64, @floatFromInt(self.cost_den))
        else
            std.math.inf(f64);
        // Penalize longer paths: each extra hop adds 0.01 to the score.
        const length_penalty: f64 = @as(f64, @floatFromInt(self.hop_count)) * 0.01;
        // Penalize low liquidity: inverse of liquidity, capped.
        const liq_penalty: f64 = if (self.liquidity > 0)
            1.0 / @as(f64, @floatFromInt(self.liquidity))
        else
            1000.0;
        return cost + length_penalty + liq_penalty;
    }
};

// ---------------------------------------------------------------------------
// Graph model — nodes are (account, currency) pairs, edges are trust lines
// or DEX order book crossings.
// ---------------------------------------------------------------------------

/// Represents one side of a trust line relationship that the PathFinder
/// can traverse.
pub const TrustLineEdge = struct {
    /// The two accounts on this trust line.
    account_a: types.AccountID,
    account_b: types.AccountID,
    /// Currency of the trust line.
    currency: types.CurrencyCode,
    /// Available liquidity (how much can flow through this edge).
    available: u64,
    /// True if the no-ripple flag blocks traversal through account_b.
    no_ripple_a: bool = false,
    no_ripple_b: bool = false,
    /// True if either side is frozen.
    frozen: bool = false,
};

/// Represents a DEX order book crossing that converts one currency to another.
pub const OrderBookEdge = struct {
    /// Currency being sold (input).
    taker_pays_currency: types.CurrencyCode,
    taker_pays_issuer: ?types.AccountID = null,
    /// Currency being bought (output).
    taker_gets_currency: types.CurrencyCode,
    taker_gets_issuer: ?types.AccountID = null,
    /// Best available quality (taker_pays / taker_gets). Lower is better.
    quality_num: u64,
    quality_den: u64,
    /// Depth of liquidity at this quality level.
    depth: u64,
};

// ---------------------------------------------------------------------------
// Graph node identifier
// ---------------------------------------------------------------------------

const NodeId = struct {
    account: types.AccountID,
    currency_bytes: [20]u8,
};

fn nodeIdHash(key: NodeId) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&key.account);
    hasher.update(&key.currency_bytes);
    return hasher.final();
}

fn nodeIdEql(a: NodeId, b: NodeId) bool {
    return std.mem.eql(u8, &a.account, &b.account) and
        std.mem.eql(u8, &a.currency_bytes, &b.currency_bytes);
}

const NodeIdContext = struct {
    pub fn hash(_: NodeIdContext, key: NodeId) u64 {
        return nodeIdHash(key);
    }
    pub fn eql(_: NodeIdContext, a: NodeId, b: NodeId) bool {
        return nodeIdEql(a, b);
    }
};

// ---------------------------------------------------------------------------
// BFS state for path discovery
// ---------------------------------------------------------------------------

const BfsEntry = struct {
    node: NodeId,
    /// Index of the parent entry in the visited list, or null for the source.
    parent_idx: ?u32,
    /// The step that led to this node.
    step: ?PathStep,
    /// Accumulated cost numerator.
    cost_num: u64,
    /// Accumulated cost denominator.
    cost_den: u64,
    /// Minimum liquidity along the path so far.
    min_liquidity: u64,
    /// Depth (number of hops from source).
    depth: u32,
};

// ---------------------------------------------------------------------------
// PathFinder
// ---------------------------------------------------------------------------

/// XRPL payment path finder. Uses BFS through the trust graph and DEX order
/// books to discover optimal payment routes from source to destination.
pub const PathFinder = struct {
    allocator: std.mem.Allocator,
    /// Maximum number of alternative paths to return (per XRPL spec: 4).
    max_paths: u32 = 4,
    /// Maximum number of steps per path (per XRPL spec: 6).
    max_path_length: u32 = 6,

    pub fn init(allocator: std.mem.Allocator) PathFinder {
        return PathFinder{
            .allocator = allocator,
        };
    }

    /// Find payment paths from `source` to `destination` delivering
    /// `dest_amount` of `dest_currency`.
    ///
    /// The caller provides the set of trust line edges and order book edges
    /// that constitute the current ledger state.
    ///
    /// Returns up to `max_paths` paths, ranked by score (best first).
    /// Caller owns the returned slice and each path's steps slice.
    pub fn findPaths(
        self: *PathFinder,
        source: types.AccountID,
        destination: types.AccountID,
        dest_currency: types.CurrencyCode,
        dest_amount: u64,
        trust_lines: []const TrustLineEdge,
        order_books: []const OrderBookEdge,
    ) ![]PaymentPath {
        _ = dest_amount; // used for future liquidity filtering

        var result_paths = std.ArrayList(PaymentPath).init(self.allocator);
        errdefer {
            for (result_paths.items) |p| self.allocator.free(p.steps);
            result_paths.deinit();
        }

        // BFS queue and visited tracking.
        var queue = std.ArrayList(BfsEntry).init(self.allocator);
        defer queue.deinit();

        // Track visited (account, currency) pairs to prevent cycles.
        var visited = std.HashMap(NodeId, void, NodeIdContext, 80).init(self.allocator);
        defer visited.deinit();

        // Seed: source node with the destination currency (for same-currency paths)
        // and also with every currency the source holds (for cross-currency paths).
        const source_node = NodeId{
            .account = source,
            .currency_bytes = dest_currency.bytes,
        };

        try queue.append(BfsEntry{
            .node = source_node,
            .parent_idx = null,
            .step = null,
            .cost_num = 0,
            .cost_den = 1,
            .min_liquidity = std.math.maxInt(u64),
            .depth = 0,
        });

        // Also seed with currencies the source can access via order books.
        for (order_books) |ob| {
            if (std.mem.eql(u8, &ob.taker_gets_currency.bytes, &dest_currency.bytes)) {
                // There's an order book that sells dest_currency for
                // taker_pays_currency. The source might pay in taker_pays_currency.
                const alt_node = NodeId{
                    .account = source,
                    .currency_bytes = ob.taker_pays_currency.bytes,
                };
                if (!visited.contains(alt_node)) {
                    try queue.append(BfsEntry{
                        .node = alt_node,
                        .parent_idx = null,
                        .step = null,
                        .cost_num = 0,
                        .cost_den = 1,
                        .min_liquidity = std.math.maxInt(u64),
                        .depth = 0,
                    });
                }
            }
        }

        // BFS main loop.
        var head: usize = 0;
        while (head < queue.items.len and result_paths.items.len < self.max_paths) {
            const current = queue.items[head];
            head += 1;

            // Depth limit.
            if (current.depth > self.max_path_length) continue;

            // Check if we reached the destination with the right currency.
            if (std.mem.eql(u8, &current.node.account, &destination) and
                std.mem.eql(u8, &current.node.currency_bytes, &dest_currency.bytes) and
                current.depth > 0)
            {
                // Reconstruct path.
                const path = try self.reconstructPath(queue.items, @as(u32, @intCast(head - 1)));
                if (path) |p| {
                    var payment_path = p;
                    payment_path.cost_num = current.cost_num;
                    payment_path.cost_den = current.cost_den;
                    payment_path.hop_count = current.depth;
                    payment_path.liquidity = current.min_liquidity;
                    try result_paths.append(payment_path);

                    if (result_paths.items.len >= self.max_paths) break;
                }
                continue;
            }

            // Mark visited to prevent cycles.
            const visit_result = try visited.getOrPut(current.node);
            if (visit_result.found_existing) continue;

            // Explore trust line edges.
            for (trust_lines) |tl| {
                if (tl.frozen) continue;

                // Check if this trust line is relevant to the current node.
                const is_a = std.mem.eql(u8, &tl.account_a, &current.node.account);
                const is_b = std.mem.eql(u8, &tl.account_b, &current.node.account);
                if (!is_a and !is_b) continue;

                if (!std.mem.eql(u8, &tl.currency.bytes, &current.node.currency_bytes)) continue;

                // Determine the peer account.
                const peer = if (is_a) tl.account_b else tl.account_a;

                // Check no-ripple: if the current account (as intermediary) has
                // no-ripple set, rippling through it is blocked.
                if (current.depth > 0) {
                    // Current node is an intermediary.
                    if (is_a and tl.no_ripple_a) continue;
                    if (is_b and tl.no_ripple_b) continue;
                }

                // Don't revisit source.
                if (current.depth > 0 and std.mem.eql(u8, &peer, &source)) continue;

                const next_node = NodeId{
                    .account = peer,
                    .currency_bytes = tl.currency.bytes,
                };

                if (visited.contains(next_node)) continue;

                const next_entry = BfsEntry{
                    .node = next_node,
                    .parent_idx = @intCast(head - 1),
                    .step = PathStep{
                        .account = peer,
                        .currency = tl.currency,
                        .issuer = null,
                    },
                    .cost_num = current.cost_num,
                    .cost_den = current.cost_den,
                    .min_liquidity = @min(current.min_liquidity, tl.available),
                    .depth = current.depth + 1,
                };

                try queue.append(next_entry);
            }

            // Explore DEX order book edges (currency crossings).
            for (order_books) |ob| {
                // An order book selling currency X for currency Y means:
                // taker_pays = X (what the taker pays), taker_gets = Y (what the taker gets).
                // We can traverse from (account, X) to (account, Y) by crossing.
                if (!std.mem.eql(u8, &ob.taker_pays_currency.bytes, &current.node.currency_bytes))
                    continue;

                const next_node = NodeId{
                    .account = current.node.account,
                    .currency_bytes = ob.taker_gets_currency.bytes,
                };

                if (visited.contains(next_node)) continue;

                // Accumulate cost: multiply the quality ratios.
                // new_cost = old_cost + quality (for simplicity, we add rather than multiply
                // since we're doing BFS not Dijkstra — costs are approximations).
                const new_cost_num = if (current.cost_num == 0)
                    ob.quality_num
                else
                    current.cost_num *| ob.quality_num;
                const new_cost_den = if (current.cost_den == 1 and current.cost_num == 0)
                    ob.quality_den
                else
                    current.cost_den *| ob.quality_den;

                var step = PathStep{
                    .currency = ob.taker_gets_currency,
                    .issuer = ob.taker_gets_issuer,
                };
                // If the issuer is set, also include it.
                if (ob.taker_gets_issuer) |issuer| {
                    step.issuer = issuer;
                }

                const next_entry = BfsEntry{
                    .node = next_node,
                    .parent_idx = @intCast(head - 1),
                    .step = step,
                    .cost_num = new_cost_num,
                    .cost_den = new_cost_den,
                    .min_liquidity = @min(current.min_liquidity, ob.depth),
                    .depth = current.depth + 1,
                };

                try queue.append(next_entry);
            }
        }

        // Sort results by score (lower is better).
        const items = result_paths.items;
        std.mem.sort(PaymentPath, items, {}, struct {
            fn lessThan(_: void, a: PaymentPath, b: PaymentPath) bool {
                return a.score() < b.score();
            }
        }.lessThan);

        return result_paths.toOwnedSlice();
    }

    /// Reconstruct a path by walking parent pointers from the given BFS entry
    /// back to the source.
    fn reconstructPath(self: *PathFinder, entries: []const BfsEntry, end_idx: u32) !?PaymentPath {
        // Count steps.
        var count: u32 = 0;
        var idx: ?u32 = end_idx;
        while (idx) |i| {
            if (entries[i].step != null) count += 1;
            idx = entries[i].parent_idx;
        }

        if (count == 0) return null;

        const steps = try self.allocator.alloc(PathStep, count);
        errdefer self.allocator.free(steps);

        // Fill in reverse.
        var pos: u32 = count;
        idx = end_idx;
        while (idx) |i| {
            if (entries[i].step) |step| {
                pos -= 1;
                steps[pos] = step;
            }
            idx = entries[i].parent_idx;
        }

        return PaymentPath{
            .steps = steps,
        };
    }

    /// Estimate the cost of an existing payment path given the current
    /// order book edges. For trust-line-only hops, cost is 0. For DEX
    /// crossings, uses the best available offer quality.
    pub fn estimatePathCost(
        self: *PathFinder,
        path: PaymentPath,
        order_books: []const OrderBookEdge,
    ) struct { num: u64, den: u64 } {
        _ = self;
        var total_num: u64 = 0;
        var total_den: u64 = 1;

        for (path.steps) |step| {
            if (step.account != null and step.currency == null) {
                // Trust line hop: 0 cost.
                continue;
            }
            if (step.currency) |currency| {
                // DEX crossing: find best matching order book.
                for (order_books) |ob| {
                    if (std.mem.eql(u8, &ob.taker_gets_currency.bytes, &currency.bytes)) {
                        total_num = if (total_num == 0) ob.quality_num else total_num *| ob.quality_num;
                        total_den = total_den *| ob.quality_den;
                        break;
                    }
                }
            }
        }

        return .{ .num = total_num, .den = total_den };
    }
};

// ===========================================================================
// Test helpers
// ===========================================================================

fn makeAccount(id: u8) types.AccountID {
    var account: types.AccountID = [_]u8{0} ** 20;
    account[19] = id;
    return account;
}

// ===========================================================================
// Tests
// ===========================================================================

test "pathfinder initialization" {
    const allocator = std.testing.allocator;
    const finder = PathFinder.init(allocator);

    try std.testing.expectEqual(@as(u32, 4), finder.max_paths);
    try std.testing.expectEqual(@as(u32, 6), finder.max_path_length);
}

test "direct payment — same currency, single hop" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const usd = try types.CurrencyCode.fromStandard("USD");

    // Single trust line: Alice <-> Bob for USD.
    const trust_lines = [_]TrustLineEdge{
        .{
            .account_a = alice,
            .account_b = bob,
            .currency = usd,
            .available = 1000,
        },
    };

    const paths = try finder.findPaths(
        alice,
        bob,
        usd,
        100,
        &trust_lines,
        &[_]OrderBookEdge{},
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    try std.testing.expect(paths.len >= 1);
    // The direct path should be one step: account=bob, currency=USD.
    try std.testing.expectEqual(@as(usize, 1), paths[0].steps.len);
    try std.testing.expect(std.mem.eql(u8, &paths[0].steps[0].account.?, &bob));
    try std.testing.expectEqual(@as(u32, 1), paths[0].hop_count);
}

test "two-hop through intermediary via trust lines" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const carol = makeAccount(3);
    const usd = try types.CurrencyCode.fromStandard("USD");

    // Alice <-> Bob, Bob <-> Carol, both for USD.
    const trust_lines = [_]TrustLineEdge{
        .{
            .account_a = alice,
            .account_b = bob,
            .currency = usd,
            .available = 500,
        },
        .{
            .account_a = bob,
            .account_b = carol,
            .currency = usd,
            .available = 300,
        },
    };

    const paths = try finder.findPaths(
        alice,
        carol,
        usd,
        100,
        &trust_lines,
        &[_]OrderBookEdge{},
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    try std.testing.expect(paths.len >= 1);
    // Should be a two-hop path: Alice -> Bob -> Carol.
    try std.testing.expectEqual(@as(usize, 2), paths[0].steps.len);
    try std.testing.expect(std.mem.eql(u8, &paths[0].steps[0].account.?, &bob));
    try std.testing.expect(std.mem.eql(u8, &paths[0].steps[1].account.?, &carol));
    try std.testing.expectEqual(@as(u32, 2), paths[0].hop_count);
    // Liquidity should be min(500, 300) = 300.
    try std.testing.expectEqual(@as(u64, 300), paths[0].liquidity);
}

test "cross-currency via DEX order book" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const usd = try types.CurrencyCode.fromStandard("USD");
    const eur = try types.CurrencyCode.fromStandard("EUR");

    // Alice holds EUR, wants to pay Bob in USD.
    // Trust lines: Alice has EUR, Bob accepts USD.
    const trust_lines = [_]TrustLineEdge{
        .{
            .account_a = alice,
            .account_b = bob,
            .currency = usd,
            .available = 1000,
        },
    };

    // DEX: order book converting EUR -> USD at rate 1.1 (110/100).
    const order_books = [_]OrderBookEdge{
        .{
            .taker_pays_currency = eur,
            .taker_gets_currency = usd,
            .quality_num = 110,
            .quality_den = 100,
            .depth = 5000,
        },
    };

    const paths = try finder.findPaths(
        alice,
        bob,
        usd,
        100,
        &trust_lines,
        &order_books,
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    // Should find at least the direct USD path. May also find EUR->USD crossing.
    try std.testing.expect(paths.len >= 1);
}

test "multiple paths found and ranked" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const carol = makeAccount(3);
    const dave = makeAccount(4);
    const usd = try types.CurrencyCode.fromStandard("USD");

    // Two possible routes: Alice->Bob->Dave and Alice->Carol->Dave.
    const trust_lines = [_]TrustLineEdge{
        .{
            .account_a = alice,
            .account_b = bob,
            .currency = usd,
            .available = 200,
        },
        .{
            .account_a = bob,
            .account_b = dave,
            .currency = usd,
            .available = 200,
        },
        .{
            .account_a = alice,
            .account_b = carol,
            .currency = usd,
            .available = 800,
        },
        .{
            .account_a = carol,
            .account_b = dave,
            .currency = usd,
            .available = 800,
        },
    };

    const paths = try finder.findPaths(
        alice,
        dave,
        usd,
        100,
        &trust_lines,
        &[_]OrderBookEdge{},
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    // Should find both paths.
    try std.testing.expect(paths.len >= 2);

    // Paths should be ranked: the one with higher liquidity (Carol route: 800)
    // should score better than the one with lower liquidity (Bob route: 200).
    try std.testing.expect(paths[0].liquidity >= paths[1].liquidity);
}

test "no path exists returns empty" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const carol = makeAccount(3);
    const usd = try types.CurrencyCode.fromStandard("USD");
    const eur = try types.CurrencyCode.fromStandard("EUR");

    // Alice has a trust line with Bob in EUR, but Carol only accepts USD.
    // No connection between the two currencies and no DEX order book.
    const trust_lines = [_]TrustLineEdge{
        .{
            .account_a = alice,
            .account_b = bob,
            .currency = eur,
            .available = 1000,
        },
    };

    const paths = try finder.findPaths(
        alice,
        carol,
        usd,
        100,
        &trust_lines,
        &[_]OrderBookEdge{},
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "max path length enforced" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);
    // Set a tight limit for testing.
    finder.max_path_length = 2;

    const a = makeAccount(1);
    const b = makeAccount(2);
    const c = makeAccount(3);
    const d = makeAccount(4);
    const usd = try types.CurrencyCode.fromStandard("USD");

    // Chain: A -> B -> C -> D requires 3 hops, but limit is 2.
    const trust_lines = [_]TrustLineEdge{
        .{ .account_a = a, .account_b = b, .currency = usd, .available = 1000 },
        .{ .account_a = b, .account_b = c, .currency = usd, .available = 1000 },
        .{ .account_a = c, .account_b = d, .currency = usd, .available = 1000 },
    };

    const paths = try finder.findPaths(
        a,
        d,
        usd,
        100,
        &trust_lines,
        &[_]OrderBookEdge{},
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    // The 3-hop path exceeds the limit of 2, so no path should be found.
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "no-ripple flag blocks path through intermediary" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const carol = makeAccount(3);
    const usd = try types.CurrencyCode.fromStandard("USD");

    // Alice <-> Bob <-> Carol, but Bob has no-ripple set.
    const trust_lines = [_]TrustLineEdge{
        .{
            .account_a = alice,
            .account_b = bob,
            .currency = usd,
            .available = 1000,
            .no_ripple_b = true, // Bob's side blocks rippling
        },
        .{
            .account_a = bob,
            .account_b = carol,
            .currency = usd,
            .available = 1000,
            .no_ripple_a = true, // Bob's side blocks rippling
        },
    };

    const paths = try finder.findPaths(
        alice,
        carol,
        usd,
        100,
        &trust_lines,
        &[_]OrderBookEdge{},
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    // Bob has no-ripple on both sides, so rippling through Bob is blocked.
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "frozen trust line is not traversed" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);

    const alice = makeAccount(1);
    const bob = makeAccount(2);
    const usd = try types.CurrencyCode.fromStandard("USD");

    const trust_lines = [_]TrustLineEdge{
        .{
            .account_a = alice,
            .account_b = bob,
            .currency = usd,
            .available = 1000,
            .frozen = true,
        },
    };

    const paths = try finder.findPaths(
        alice,
        bob,
        usd,
        100,
        &trust_lines,
        &[_]OrderBookEdge{},
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "max 4 alternative paths returned" {
    const allocator = std.testing.allocator;
    var finder = PathFinder.init(allocator);

    const src = makeAccount(1);
    const dst = makeAccount(10);
    const usd = try types.CurrencyCode.fromStandard("USD");

    // Create 6 independent intermediaries, each providing a path.
    var trust_lines_buf: [12]TrustLineEdge = undefined;
    for (0..6) |i| {
        const intermediary = makeAccount(@as(u8, @intCast(i + 2)));
        trust_lines_buf[i * 2] = TrustLineEdge{
            .account_a = src,
            .account_b = intermediary,
            .currency = usd,
            .available = @as(u64, @intCast((i + 1) * 100)),
        };
        trust_lines_buf[i * 2 + 1] = TrustLineEdge{
            .account_a = intermediary,
            .account_b = dst,
            .currency = usd,
            .available = @as(u64, @intCast((i + 1) * 100)),
        };
    }

    const paths = try finder.findPaths(
        src,
        dst,
        usd,
        50,
        &trust_lines_buf,
        &[_]OrderBookEdge{},
    );
    defer {
        for (paths) |p| allocator.free(p.steps);
        allocator.free(paths);
    }

    // Should return at most 4 paths even though 6 are possible.
    try std.testing.expect(paths.len <= 4);
    try std.testing.expect(paths.len > 0);
}
