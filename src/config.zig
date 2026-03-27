const std = @import("std");

/// Configuration management
pub const Config = struct {
    // Server settings
    rpc_port: u16 = 5005,
    peer_port: u16 = 51235,
    websocket_port: u16 = 6006,

    // Network settings
    network_id: u32 = 0, // 0 = mainnet, 1 = testnet
    max_peers: u32 = 50,

    // Consensus settings
    validation_quorum: u8 = 80, // 80% threshold
    ledger_time_resolution: u32 = 10, // seconds

    // Database settings
    database_path: []const u8,
    cache_size_mb: u32 = 512,

    // Logging
    log_level: LogLevel = .info,
    log_file: ?[]const u8 = null,

    allocator: std.mem.Allocator,

    /// Load configuration from file
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        _ = path;
        // TODO: Implement TOML/JSON parsing
        // For now, return defaults
        return Config{
            .database_path = try allocator.dupe(u8, "data"),
            .allocator = allocator,
        };
    }

    /// Load from environment variables and command line
    pub fn loadFromEnv(allocator: std.mem.Allocator) !Config {
        var config = Config{
            .database_path = try allocator.dupe(u8, "data"),
            .allocator = allocator,
        };

        // Check environment variables
        if (std.process.getEnvVarOwned(allocator, "RPC_PORT")) |port_str| {
            defer allocator.free(port_str);
            config.rpc_port = try std.fmt.parseInt(u16, port_str, 10);
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "NETWORK")) |network| {
            defer allocator.free(network);
            if (std.mem.eql(u8, network, "testnet")) {
                config.network_id = 1;
            }
        } else |_| {}

        return config;
    }

    /// Create default configuration
    pub fn default(allocator: std.mem.Allocator) !Config {
        return Config{
            .database_path = try allocator.dupe(u8, "data"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.database_path);
        if (self.log_file) |file| {
            self.allocator.free(file);
        }
    }
};

/// Log levels (matching syslog severity, ascending)
pub const LogLevel = enum(u3) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    @"error" = 4,
    fatal = 5,

    pub fn fromString(str: []const u8) ?LogLevel {
        if (std.mem.eql(u8, str, "trace")) return .trace;
        if (std.mem.eql(u8, str, "debug")) return .debug;
        if (std.mem.eql(u8, str, "info")) return .info;
        if (std.mem.eql(u8, str, "warn")) return .warn;
        if (std.mem.eql(u8, str, "error")) return .@"error";
        if (std.mem.eql(u8, str, "fatal")) return .fatal;
        return null;
    }

    pub fn asText(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .@"error" => "error",
            .fatal => "fatal",
        };
    }
};

test "config default" {
    const allocator = std.testing.allocator;
    var config = try Config.default(allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 5005), config.rpc_port);
    try std.testing.expectEqual(@as(u8, 80), config.validation_quorum);
}

test "log level parsing" {
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("info").?);
    try std.testing.expectEqual(LogLevel.@"error", LogLevel.fromString("error").?);
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString("invalid"));
}
