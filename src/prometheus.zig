const std = @import("std");

// ── Counter ──────────────────────────────────────────────────────────────────
/// Monotonically increasing counter, thread-safe via atomics.
pub const Counter = struct {
    value: std.atomic.Value(u64),
    name: []const u8,
    help: []const u8,

    pub fn init(name: []const u8, help: []const u8) Counter {
        return .{
            .value = std.atomic.Value(u64).init(0),
            .name = name,
            .help = help,
        };
    }

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn incBy(self: *Counter, n: u64) void {
        _ = self.value.fetchAdd(n, .monotonic);
    }

    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }
};

// ── Gauge ────────────────────────────────────────────────────────────────────
/// Value that can go up and down, thread-safe via atomics.
pub const Gauge = struct {
    value: std.atomic.Value(i64),
    name: []const u8,
    help: []const u8,

    pub fn init(name: []const u8, help: []const u8) Gauge {
        return .{
            .value = std.atomic.Value(i64).init(0),
            .name = name,
            .help = help,
        };
    }

    pub fn set(self: *Gauge, val: i64) void {
        self.value.store(val, .monotonic);
    }

    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }
};

// ── Histogram ────────────────────────────────────────────────────────────────
/// Distribution of observed values across predefined buckets.
pub const Histogram = struct {
    pub const bucket_boundaries = [_]f64{
        0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
    };
    pub const num_buckets = bucket_boundaries.len;

    /// Each bucket count is stored as an atomic u64.
    bucket_counts: [num_buckets]std.atomic.Value(u64),
    /// +Inf bucket is just the total count.
    count_val: std.atomic.Value(u64),
    /// Sum stored as atomic u64 holding the bit-pattern of an f64.
    sum_bits: std.atomic.Value(u64),
    name: []const u8,
    help: []const u8,

    pub fn init(name: []const u8, help: []const u8) Histogram {
        var h: Histogram = undefined;
        h.name = name;
        h.help = help;
        h.count_val = std.atomic.Value(u64).init(0);
        h.sum_bits = std.atomic.Value(u64).init(@bitCast(@as(f64, 0.0)));
        for (0..num_buckets) |i| {
            h.bucket_counts[i] = std.atomic.Value(u64).init(0);
        }
        return h;
    }

    pub fn observe(self: *Histogram, value: f64) void {
        // Increment bucket counts for all buckets whose boundary >= value.
        for (0..num_buckets) |i| {
            if (value <= bucket_boundaries[i]) {
                _ = self.bucket_counts[i].fetchAdd(1, .monotonic);
            }
        }
        _ = self.count_val.fetchAdd(1, .monotonic);

        // Atomically add to sum using CAS loop on bit-casted f64.
        while (true) {
            const old_bits = self.sum_bits.load(.monotonic);
            const old_sum: f64 = @bitCast(old_bits);
            const new_sum = old_sum + value;
            const new_bits: u64 = @bitCast(new_sum);
            if (self.sum_bits.cmpxchgWeak(old_bits, new_bits, .monotonic, .monotonic) == null) {
                break;
            }
        }
    }

    pub fn count(self: *const Histogram) u64 {
        return self.count_val.load(.monotonic);
    }

    pub fn sum(self: *const Histogram) f64 {
        const bits = self.sum_bits.load(.monotonic);
        return @bitCast(bits);
    }

    pub fn bucketCount(self: *const Histogram, index: usize) u64 {
        return self.bucket_counts[index].load(.monotonic);
    }
};

// ── MetricsRegistry ──────────────────────────────────────────────────────────
pub const MetricsRegistry = struct {
    counters: std.ArrayList(*Counter),
    gauges: std.ArrayList(*Gauge),
    histograms: std.ArrayList(*Histogram),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MetricsRegistry {
        return .{
            .counters = std.ArrayList(*Counter).init(allocator),
            .gauges = std.ArrayList(*Gauge).init(allocator),
            .histograms = std.ArrayList(*Histogram).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MetricsRegistry) void {
        for (self.counters.items) |c| self.allocator.destroy(c);
        for (self.gauges.items) |g| self.allocator.destroy(g);
        for (self.histograms.items) |h| self.allocator.destroy(h);
        self.counters.deinit();
        self.gauges.deinit();
        self.histograms.deinit();
    }

    pub fn registerCounter(self: *MetricsRegistry, name: []const u8, help: []const u8) !*Counter {
        const c = try self.allocator.create(Counter);
        c.* = Counter.init(name, help);
        try self.counters.append(c);
        return c;
    }

    pub fn registerGauge(self: *MetricsRegistry, name: []const u8, help: []const u8) !*Gauge {
        const g = try self.allocator.create(Gauge);
        g.* = Gauge.init(name, help);
        try self.gauges.append(g);
        return g;
    }

    pub fn registerHistogram(self: *MetricsRegistry, name: []const u8, help: []const u8) !*Histogram {
        const h = try self.allocator.create(Histogram);
        h.* = Histogram.init(name, help);
        try self.histograms.append(h);
        return h;
    }
};

// ── Prometheus text format export ────────────────────────────────────────────

pub fn exportPrometheus(registry: *MetricsRegistry, writer: anytype) !void {
    // Counters
    for (registry.counters.items) |c| {
        try writer.print("# HELP {s} {s}\n", .{ c.name, c.help });
        try writer.print("# TYPE {s} counter\n", .{c.name});
        try writer.print("{s} {d}\n", .{ c.name, c.get() });
    }

    // Gauges
    for (registry.gauges.items) |g| {
        try writer.print("# HELP {s} {s}\n", .{ g.name, g.help });
        try writer.print("# TYPE {s} gauge\n", .{g.name});
        try writer.print("{s} {d}\n", .{ g.name, g.get() });
    }

    // Histograms
    for (registry.histograms.items) |h| {
        try writer.print("# HELP {s} {s}\n", .{ h.name, h.help });
        try writer.print("# TYPE {s} histogram\n", .{h.name});

        var cumulative: u64 = 0;
        for (0..Histogram.num_buckets) |i| {
            cumulative = h.bucketCount(i);
            const boundary = Histogram.bucket_boundaries[i];
            // Format le label: if the boundary is an integer value, print without
            // unnecessary fractional digits; otherwise use up to 3 decimal places.
            if (boundary == @floor(boundary) and boundary < 1000.0) {
                try writer.print("{s}_bucket{{le=\"{d:.1}\"}} {d}\n", .{ h.name, boundary, cumulative });
            } else {
                try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{ h.name, boundary, cumulative });
            }
        }
        // +Inf bucket
        try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ h.name, h.count() });
        try writer.print("{s}_count {d}\n", .{ h.name, h.count() });
        try writer.print("{s}_sum {d}\n", .{ h.name, h.sum() });
    }
}

// ── Pre-defined XRPL metrics ────────────────────────────────────────────────

pub const XrplMetrics = struct {
    registry: MetricsRegistry,

    // Counters
    transactions_total: *Counter,
    rpc_requests_total: *Counter,

    // Histograms
    ledger_close_seconds: *Histogram,
    rpc_latency_seconds: *Histogram,

    // Gauges
    peer_count: *Gauge,
    current_ledger_sequence: *Gauge,
    fee_base_drops: *Gauge,
    account_count: *Gauge,

    pub fn init(allocator: std.mem.Allocator) !XrplMetrics {
        var reg = MetricsRegistry.init(allocator);

        const transactions_total = try reg.registerCounter("xrpl_transactions_total", "Total XRPL transactions processed");
        const rpc_requests_total = try reg.registerCounter("xrpl_rpc_requests_total", "Total RPC requests handled");

        const ledger_close_seconds = try reg.registerHistogram("xrpl_ledger_close_seconds", "Histogram of ledger close durations in seconds");
        const rpc_latency_seconds = try reg.registerHistogram("xrpl_rpc_latency_seconds", "Histogram of RPC request latencies in seconds");

        const peer_count = try reg.registerGauge("xrpl_peer_count", "Number of connected peers");
        const current_ledger_sequence = try reg.registerGauge("xrpl_current_ledger_sequence", "Current validated ledger sequence number");
        const fee_base_drops = try reg.registerGauge("xrpl_fee_base_drops", "Current base fee in drops");
        const account_count = try reg.registerGauge("xrpl_account_count", "Total number of funded accounts");

        return .{
            .registry = reg,
            .transactions_total = transactions_total,
            .rpc_requests_total = rpc_requests_total,
            .ledger_close_seconds = ledger_close_seconds,
            .rpc_latency_seconds = rpc_latency_seconds,
            .peer_count = peer_count,
            .current_ledger_sequence = current_ledger_sequence,
            .fee_base_drops = fee_base_drops,
            .account_count = account_count,
        };
    }

    pub fn deinit(self: *XrplMetrics) void {
        self.registry.deinit();
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "counter increment and read" {
    var c = Counter.init("test_counter", "A test counter");
    try std.testing.expectEqual(@as(u64, 0), c.get());

    c.inc();
    try std.testing.expectEqual(@as(u64, 1), c.get());

    c.incBy(5);
    try std.testing.expectEqual(@as(u64, 6), c.get());

    c.inc();
    try std.testing.expectEqual(@as(u64, 7), c.get());
}

test "gauge set inc dec" {
    var g = Gauge.init("test_gauge", "A test gauge");
    try std.testing.expectEqual(@as(i64, 0), g.get());

    g.set(42);
    try std.testing.expectEqual(@as(i64, 42), g.get());

    g.inc();
    try std.testing.expectEqual(@as(i64, 43), g.get());

    g.dec();
    g.dec();
    try std.testing.expectEqual(@as(i64, 41), g.get());

    g.set(-10);
    try std.testing.expectEqual(@as(i64, -10), g.get());
}

test "histogram observe and bucket distribution" {
    var h = Histogram.init("test_histogram", "A test histogram");

    // Observe values that fall into different buckets
    h.observe(0.002); // <= 0.005, 0.01, 0.025, ...
    h.observe(0.02); // <= 0.025, 0.05, ...
    h.observe(0.5); // <= 0.5, 1.0, ...
    h.observe(3.0); // <= 5.0, 10.0
    h.observe(15.0); // exceeds all boundaries

    try std.testing.expectEqual(@as(u64, 5), h.count());
    try std.testing.expect(h.sum() > 18.5 and h.sum() < 18.6);

    // Bucket 0: le=0.001 -> only values <= 0.001 -> 0
    try std.testing.expectEqual(@as(u64, 0), h.bucketCount(0));
    // Bucket 1: le=0.005 -> values <= 0.005 -> 1 (0.002)
    try std.testing.expectEqual(@as(u64, 1), h.bucketCount(1));
    // Bucket 3: le=0.025 -> values <= 0.025 -> 2 (0.002, 0.02)
    try std.testing.expectEqual(@as(u64, 2), h.bucketCount(3));
    // Bucket 7: le=0.5 -> values <= 0.5 -> 3 (0.002, 0.02, 0.5)
    try std.testing.expectEqual(@as(u64, 3), h.bucketCount(7));
    // Bucket 10: le=5.0 -> values <= 5.0 -> 4 (0.002, 0.02, 0.5, 3.0)
    try std.testing.expectEqual(@as(u64, 4), h.bucketCount(10));
    // Bucket 11: le=10.0 -> values <= 10.0 -> 4
    try std.testing.expectEqual(@as(u64, 4), h.bucketCount(11));
}

test "export produces valid prometheus format" {
    const allocator = std.testing.allocator;
    var reg = MetricsRegistry.init(allocator);
    defer reg.deinit();

    const c = try reg.registerCounter("http_requests_total", "Total HTTP requests");
    c.inc();
    c.inc();
    c.inc();

    const g = try reg.registerGauge("temperature_celsius", "Current temperature");
    g.set(23);

    const h = try reg.registerHistogram("request_duration_seconds", "Request duration");
    h.observe(0.05);
    h.observe(0.2);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try exportPrometheus(&reg, buf.writer());

    const output = buf.items;

    // Verify counter section
    try std.testing.expect(std.mem.indexOf(u8, output, "# HELP http_requests_total Total HTTP requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE http_requests_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "http_requests_total 3") != null);

    // Verify gauge section
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE temperature_celsius gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "temperature_celsius 23") != null);

    // Verify histogram section
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE request_duration_seconds histogram") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "request_duration_seconds_bucket{le=\"+Inf\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "request_duration_seconds_count 2") != null);
}

test "predefined xrpl metrics register correctly" {
    const allocator = std.testing.allocator;
    var xrpl = try XrplMetrics.init(allocator);
    defer xrpl.deinit();

    // Verify all metrics are accessible and start at zero
    try std.testing.expectEqual(@as(u64, 0), xrpl.transactions_total.get());
    try std.testing.expectEqual(@as(u64, 0), xrpl.rpc_requests_total.get());
    try std.testing.expectEqual(@as(i64, 0), xrpl.peer_count.get());
    try std.testing.expectEqual(@as(i64, 0), xrpl.current_ledger_sequence.get());
    try std.testing.expectEqual(@as(i64, 0), xrpl.fee_base_drops.get());
    try std.testing.expectEqual(@as(i64, 0), xrpl.account_count.get());
    try std.testing.expectEqual(@as(u64, 0), xrpl.ledger_close_seconds.count());
    try std.testing.expectEqual(@as(u64, 0), xrpl.rpc_latency_seconds.count());

    // Use them
    xrpl.transactions_total.incBy(100);
    xrpl.peer_count.set(25);
    xrpl.current_ledger_sequence.set(80_000_000);
    xrpl.fee_base_drops.set(10);
    xrpl.ledger_close_seconds.observe(3.5);

    try std.testing.expectEqual(@as(u64, 100), xrpl.transactions_total.get());
    try std.testing.expectEqual(@as(i64, 25), xrpl.peer_count.get());
    try std.testing.expectEqual(@as(i64, 80_000_000), xrpl.current_ledger_sequence.get());
    try std.testing.expectEqual(@as(u64, 1), xrpl.ledger_close_seconds.count());

    // Registry should have 2 counters, 4 gauges, 2 histograms
    try std.testing.expectEqual(@as(usize, 2), xrpl.registry.counters.items.len);
    try std.testing.expectEqual(@as(usize, 4), xrpl.registry.gauges.items.len);
    try std.testing.expectEqual(@as(usize, 2), xrpl.registry.histograms.items.len);
}

test "thread safety concurrent counter increments" {
    const allocator = std.testing.allocator;
    var reg = MetricsRegistry.init(allocator);
    defer reg.deinit();

    const counter = try reg.registerCounter("concurrent_counter", "Counter for concurrency test");

    const num_threads = 8;
    const increments_per_thread = 10_000;

    var threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(c: *Counter) void {
                for (0..increments_per_thread) |_| {
                    c.inc();
                }
            }
        }.run, .{counter});
    }

    for (0..num_threads) |i| {
        threads[i].join();
    }

    try std.testing.expectEqual(@as(u64, num_threads * increments_per_thread), counter.get());
}

test "histogram sum accuracy with multiple observations" {
    var h = Histogram.init("latency", "Latency histogram");

    h.observe(0.1);
    h.observe(0.2);
    h.observe(0.3);

    try std.testing.expectEqual(@as(u64, 3), h.count());

    // Sum should be 0.6 (within floating point tolerance)
    const s = h.sum();
    try std.testing.expect(s > 0.599 and s < 0.601);
}
