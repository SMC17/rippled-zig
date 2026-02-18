const std = @import("std");

/// Security hardening utilities
pub const Security = struct {
    /// Rate limiter for DoS protection
    pub const RateLimiter = struct {
        allocator: std.mem.Allocator,
        limits: std.AutoHashMap([16]u8, RateLimit), // IP -> limit
        window_ms: u64,
        max_requests: u32,

        pub fn init(allocator: std.mem.Allocator, window_ms: u64, max_requests: u32) RateLimiter {
            return RateLimiter{
                .allocator = allocator,
                .limits = std.AutoHashMap([16]u8, RateLimit).init(allocator),
                .window_ms = window_ms,
                .max_requests = max_requests,
            };
        }

        pub fn deinit(self: *RateLimiter) void {
            self.limits.deinit();
        }

        /// Check if request is allowed
        pub fn checkLimit(self: *RateLimiter, ip: [16]u8) !bool {
            const now = std.time.milliTimestamp();

            if (self.limits.get(ip)) |*limit| {
                // Check if window expired
                if (now - limit.window_start > self.window_ms) {
                    // Reset window
                    const new_limit = RateLimit{
                        .window_start = now,
                        .count = 1,
                    };
                    try self.limits.put(ip, new_limit);
                    return true;
                }

                // Check if under limit
                if (limit.count >= self.max_requests) {
                    return false; // Rate limited!
                }

                // Increment counter
                var updated = limit.*;
                updated.count += 1;
                try self.limits.put(ip, updated);
                return true;
            } else {
                // First request from this IP
                try self.limits.put(ip, RateLimit{
                    .window_start = now,
                    .count = 1,
                });
                return true;
            }
        }

        /// Clean up expired entries
        pub fn cleanup(self: *RateLimiter) void {
            const now = std.time.milliTimestamp();

            var to_remove = std.ArrayList([16]u8).init(self.allocator);
            defer to_remove.deinit();

            var it = self.limits.iterator();
            while (it.next()) |entry| {
                if (now - entry.value_ptr.window_start > self.window_ms) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                }
            }

            for (to_remove.items) |ip| {
                _ = self.limits.remove(ip);
            }
        }
    };

    /// Per-IP rate limit state
    const RateLimit = struct {
        window_start: i64,
        count: u32,
    };

    /// Input validator for preventing injection attacks
    pub const InputValidator = struct {
        /// Validate and sanitize string input
        pub fn validateString(input: []const u8, max_len: usize) ![]const u8 {
            if (input.len > max_len) return error.InputTooLong;

            // Check for null bytes
            if (std.mem.indexOfScalar(u8, input, 0) != null) {
                return error.NullByteInInput;
            }

            // Check for control characters
            for (input) |byte| {
                if (byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') {
                    return error.ControlCharacterInInput;
                }
            }

            return input;
        }

        /// Validate numeric input
        pub fn validateNumber(input: []const u8, min: i64, max: i64) !i64 {
            const value = try std.fmt.parseInt(i64, input, 10);

            if (value < min or value > max) {
                return error.NumberOutOfRange;
            }

            return value;
        }

        /// Validate hex string
        pub fn validateHex(input: []const u8) ![]const u8 {
            if (input.len % 2 != 0) return error.InvalidHexLength;

            for (input) |byte| {
                if (!std.ascii.isHex(byte)) {
                    return error.InvalidHexCharacter;
                }
            }

            return input;
        }
    };

    /// Resource quota enforcement
    pub const ResourceQuota = struct {
        max_memory_mb: u32,
        max_connections: u32,
        max_pending_txs: u32,
        max_ledger_history: u32,

        current_memory_mb: std.atomic.Value(u32),
        current_connections: std.atomic.Value(u32),
        current_pending_txs: std.atomic.Value(u32),

        pub fn init(
            max_memory_mb: u32,
            max_connections: u32,
            max_pending_txs: u32,
            max_ledger_history: u32,
        ) ResourceQuota {
            return ResourceQuota{
                .max_memory_mb = max_memory_mb,
                .max_connections = max_connections,
                .max_pending_txs = max_pending_txs,
                .max_ledger_history = max_ledger_history,
                .current_memory_mb = std.atomic.Value(u32).init(0),
                .current_connections = std.atomic.Value(u32).init(0),
                .current_pending_txs = std.atomic.Value(u32).init(0),
            };
        }

        /// Check if can allocate memory
        pub fn canAllocateMemory(self: *ResourceQuota, mb: u32) bool {
            const current = self.current_memory_mb.load(.monotonic);
            return current + mb <= self.max_memory_mb;
        }

        /// Check if can add connection
        pub fn canAddConnection(self: *ResourceQuota) bool {
            const current = self.current_connections.load(.monotonic);
            return current < self.max_connections;
        }

        /// Check if can add pending transaction
        pub fn canAddPendingTx(self: *ResourceQuota) bool {
            const current = self.current_pending_txs.load(.monotonic);
            return current < self.max_pending_txs;
        }

        /// Increment connection count
        pub fn incConnections(self: *ResourceQuota) void {
            _ = self.current_connections.fetchAdd(1, .monotonic);
        }

        /// Decrement connection count
        pub fn decConnections(self: *ResourceQuota) void {
            _ = self.current_connections.fetchSub(1, .monotonic);
        }
    };
};

test "rate limiter" {
    const allocator = std.testing.allocator;
    var limiter = Security.RateLimiter.init(allocator, 1000, 10); // 10 requests per second
    defer limiter.deinit();

    const test_ip = [_]u8{ 127, 0, 0, 1 } ++ [_]u8{0} ** 12;

    // First 10 requests should succeed
    for (0..10) |_| {
        try std.testing.expect(try limiter.checkLimit(test_ip));
    }

    // 11th should fail
    try std.testing.expect(!try limiter.checkLimit(test_ip));
}

test "input validator string" {
    const valid = "Hello World!";
    const validated = try Security.InputValidator.validateString(valid, 100);
    try std.testing.expectEqualStrings(valid, validated);

    const too_long = "a" ** 1000;
    try std.testing.expectError(error.InputTooLong, Security.InputValidator.validateString(too_long, 100));
}

test "resource quota" {
    var quota = Security.ResourceQuota.init(1024, 100, 1000, 10000);

    try std.testing.expect(quota.canAddConnection());

    quota.incConnections();
    try std.testing.expectEqual(@as(u32, 1), quota.current_connections.load(.monotonic));

    quota.decConnections();
    try std.testing.expectEqual(@as(u32, 0), quota.current_connections.load(.monotonic));
}
