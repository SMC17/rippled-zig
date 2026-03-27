const std = @import("std");
const types = @import("types.zig");

/// Metrics collection and monitoring
pub const Metrics = struct {
    allocator: std.mem.Allocator,
    start_time: i64,

    // Counters
    transactions_processed: std.atomic.Value(u64),
    ledgers_closed: std.atomic.Value(u64),
    consensus_rounds: std.atomic.Value(u64),
    rpc_requests: std.atomic.Value(u64),
    network_messages_sent: std.atomic.Value(u64),
    network_messages_received: std.atomic.Value(u64),

    // Gauges
    connected_peers: std.atomic.Value(u32),
    pending_transactions: std.atomic.Value(u32),

    // Histograms (simplified)
    consensus_durations: std.ArrayList(u64),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !Metrics {
        return Metrics{
            .allocator = allocator,
            .start_time = std.time.timestamp(),
            .transactions_processed = std.atomic.Value(u64).init(0),
            .ledgers_closed = std.atomic.Value(u64).init(0),
            .consensus_rounds = std.atomic.Value(u64).init(0),
            .rpc_requests = std.atomic.Value(u64).init(0),
            .network_messages_sent = std.atomic.Value(u64).init(0),
            .network_messages_received = std.atomic.Value(u64).init(0),
            .connected_peers = std.atomic.Value(u32).init(0),
            .pending_transactions = std.atomic.Value(u32).init(0),
            .consensus_durations = try std.ArrayList(u64).initCapacity(allocator, 100),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Metrics) void {
        self.consensus_durations.deinit();
    }

    /// Increment transaction counter
    pub fn incTransactions(self: *Metrics) void {
        _ = self.transactions_processed.fetchAdd(1, .monotonic);
    }

    /// Increment ledger counter
    pub fn incLedgers(self: *Metrics) void {
        _ = self.ledgers_closed.fetchAdd(1, .monotonic);
    }

    /// Increment consensus round counter
    pub fn incConsensusRounds(self: *Metrics) void {
        _ = self.consensus_rounds.fetchAdd(1, .monotonic);
    }

    /// Increment RPC request counter
    pub fn incRpcRequests(self: *Metrics) void {
        _ = self.rpc_requests.fetchAdd(1, .monotonic);
    }

    /// Record consensus duration
    pub fn recordConsensusDuration(self: *Metrics, duration_ms: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.consensus_durations.append(duration_ms);

        // Keep only last 100
        if (self.consensus_durations.items.len > 100) {
            _ = self.consensus_durations.orderedRemove(0);
        }
    }

    /// Set connected peers gauge
    pub fn setPeers(self: *Metrics, count: u32) void {
        self.connected_peers.store(count, .monotonic);
    }

    /// Set pending transactions gauge
    pub fn setPendingTxs(self: *Metrics, count: u32) void {
        self.pending_transactions.store(count, .monotonic);
    }

    /// Get uptime in seconds
    pub fn getUptime(self: *const Metrics) i64 {
        return std.time.timestamp() - self.start_time;
    }

    /// Get average consensus duration
    pub fn getAverageConsensusDuration(self: *Metrics) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.consensus_durations.items.len == 0) return 0.0;

        var sum: u64 = 0;
        for (self.consensus_durations.items) |duration| {
            sum += duration;
        }

        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.consensus_durations.items.len));
    }

    /// Export metrics in Prometheus format
    pub fn exportPrometheus(self: *Metrics, allocator: std.mem.Allocator) ![]u8 {
        const uptime = self.getUptime();
        const avg_consensus = self.getAverageConsensusDuration();

        return try std.fmt.allocPrint(allocator,
            \\# HELP rippled_uptime_seconds Node uptime in seconds
            \\# TYPE rippled_uptime_seconds gauge
            \\rippled_uptime_seconds {d}
            \\
            \\# HELP rippled_transactions_total Total transactions processed
            \\# TYPE rippled_transactions_total counter
            \\rippled_transactions_total {d}
            \\
            \\# HELP rippled_ledgers_total Total ledgers closed
            \\# TYPE rippled_ledgers_total counter
            \\rippled_ledgers_total {d}
            \\
            \\# HELP rippled_consensus_rounds_total Total consensus rounds
            \\# TYPE rippled_consensus_rounds_total counter
            \\rippled_consensus_rounds_total {d}
            \\
            \\# HELP rippled_rpc_requests_total Total RPC requests
            \\# TYPE rippled_rpc_requests_total counter
            \\rippled_rpc_requests_total {d}
            \\
            \\# HELP rippled_connected_peers Connected peer count
            \\# TYPE rippled_connected_peers gauge
            \\rippled_connected_peers {d}
            \\
            \\# HELP rippled_pending_transactions Pending transaction count
            \\# TYPE rippled_pending_transactions gauge
            \\rippled_pending_transactions {d}
            \\
            \\# HELP rippled_avg_consensus_duration_ms Average consensus duration
            \\# TYPE rippled_avg_consensus_duration_ms gauge
            \\rippled_avg_consensus_duration_ms {d:.2}
            \\
        , .{
            uptime,
            self.transactions_processed.load(.monotonic),
            self.ledgers_closed.load(.monotonic),
            self.consensus_rounds.load(.monotonic),
            self.rpc_requests.load(.monotonic),
            self.connected_peers.load(.monotonic),
            self.pending_transactions.load(.monotonic),
            avg_consensus,
        });
    }

    /// Get metrics as JSON
    pub fn toJson(self: *Metrics, allocator: std.mem.Allocator) ![]u8 {
        const uptime = self.getUptime();
        const avg_consensus = self.getAverageConsensusDuration();

        return try std.fmt.allocPrint(allocator,
            \\{{
            \\  "uptime_seconds": {d},
            \\  "transactions_processed": {d},
            \\  "ledgers_closed": {d},
            \\  "consensus_rounds": {d},
            \\  "rpc_requests": {d},
            \\  "connected_peers": {d},
            \\  "pending_transactions": {d},
            \\  "avg_consensus_duration_ms": {d:.2}
            \\}}
        , .{
            uptime,
            self.transactions_processed.load(.monotonic),
            self.ledgers_closed.load(.monotonic),
            self.consensus_rounds.load(.monotonic),
            self.rpc_requests.load(.monotonic),
            self.connected_peers.load(.monotonic),
            self.pending_transactions.load(.monotonic),
            avg_consensus,
        });
    }
};

test "metrics initialization" {
    const allocator = std.testing.allocator;
    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    try std.testing.expectEqual(@as(u64, 0), metrics.transactions_processed.load(.monotonic));
}

test "metrics counters" {
    const allocator = std.testing.allocator;
    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    metrics.incTransactions();
    metrics.incTransactions();
    metrics.incLedgers();

    try std.testing.expectEqual(@as(u64, 2), metrics.transactions_processed.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.ledgers_closed.load(.monotonic));
}

test "consensus duration tracking" {
    const allocator = std.testing.allocator;
    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    try metrics.recordConsensusDuration(4500);
    try metrics.recordConsensusDuration(5000);
    try metrics.recordConsensusDuration(4800);

    const avg = metrics.getAverageConsensusDuration();
    try std.testing.expect(avg > 4700 and avg < 4900);
}
