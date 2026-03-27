const std = @import("std");
const config = @import("config.zig");

/// Comptime minimum log level — calls below this compile to nothing.
/// Override via build option if desired; default is trace (allow all).
pub const min_level: config.LogLevel = .trace;

/// A structured JSON logger.
///
/// Output format (one JSON object per line):
///   {"ts":"2026-03-26T12:00:00Z","level":"info","module":"consensus","msg":"ledger closed","seq":12345}
pub const Logger = struct {
    allocator: std.mem.Allocator,
    level: config.LogLevel,
    writer: Writer,
    mutex: std.Thread.Mutex,
    module_name: ?[]const u8,

    /// Anything that exposes `writeAll` and `print`.
    pub const Writer = struct {
        context: *anyopaque,
        writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) void,

        pub fn writeAll(self: Writer, bytes: []const u8) void {
            self.writeFn(self.context, bytes);
        }
    };

    // ── constructors ──────────────────────────────────────────────

    /// Create a logger that writes to an `std.io.AnyWriter`.
    pub fn init(
        allocator: std.mem.Allocator,
        level: config.LogLevel,
        output: Writer,
    ) Logger {
        return .{
            .allocator = allocator,
            .level = level,
            .writer = output,
            .mutex = .{},
            .module_name = null,
        };
    }

    pub fn deinit(self: *Logger) void {
        _ = self;
        // Nothing heap-allocated to free in the logger itself.
    }

    // ── scoped logger ─────────────────────────────────────────────

    /// Return a child logger with `module` preset.
    pub fn scoped(self: *Logger, module: []const u8) Logger {
        return .{
            .allocator = self.allocator,
            .level = self.level,
            .writer = self.writer,
            .mutex = .{},
            .module_name = module,
        };
    }

    // ── runtime level control ─────────────────────────────────────

    pub fn setLevel(self: *Logger, new_level: config.LogLevel) void {
        self.level = new_level;
    }

    // ── convenience methods ───────────────────────────────────────

    pub fn trace(self: *Logger, msg: []const u8, fields: anytype) void {
        if (comptime @intFromEnum(min_level) > @intFromEnum(config.LogLevel.trace)) return;
        self.logEntry(.trace, msg, fields);
    }

    pub fn debug(self: *Logger, msg: []const u8, fields: anytype) void {
        if (comptime @intFromEnum(min_level) > @intFromEnum(config.LogLevel.debug)) return;
        self.logEntry(.debug, msg, fields);
    }

    pub fn info(self: *Logger, msg: []const u8, fields: anytype) void {
        if (comptime @intFromEnum(min_level) > @intFromEnum(config.LogLevel.info)) return;
        self.logEntry(.info, msg, fields);
    }

    pub fn warn(self: *Logger, msg: []const u8, fields: anytype) void {
        if (comptime @intFromEnum(min_level) > @intFromEnum(config.LogLevel.warn)) return;
        self.logEntry(.warn, msg, fields);
    }

    pub fn err(self: *Logger, msg: []const u8, fields: anytype) void {
        if (comptime @intFromEnum(min_level) > @intFromEnum(config.LogLevel.@"error")) return;
        self.logEntry(.@"error", msg, fields);
    }

    pub fn fatal(self: *Logger, msg: []const u8, fields: anytype) void {
        if (comptime @intFromEnum(min_level) > @intFromEnum(config.LogLevel.fatal)) return;
        self.logEntry(.fatal, msg, fields);
    }

    // ── core emit ─────────────────────────────────────────────────

    fn logEntry(self: *Logger, level: config.LogLevel, msg: []const u8, fields: anytype) void {
        // Runtime gate
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        self.writeJson(w, level, msg, fields) catch return;

        const output = fbs.getWritten();
        self.writer.writeAll(output);
    }

    fn writeJson(
        self: *Logger,
        w: anytype,
        level: config.LogLevel,
        msg: []const u8,
        fields: anytype,
    ) !void {
        // Open object
        try w.writeAll("{\"ts\":\"");
        try writeTimestamp(w);
        try w.writeAll("\",\"level\":\"");
        try w.writeAll(level.asText());
        try w.writeAll("\"");

        // Module
        if (self.module_name) |mod| {
            try w.writeAll(",\"module\":\"");
            try writeJsonEscaped(w, mod);
            try w.writeAll("\"");
        }

        // Message
        try w.writeAll(",\"msg\":\"");
        try writeJsonEscaped(w, msg);
        try w.writeAll("\"");

        // Extra structured fields (from an anonymous struct / tuple)
        const Fields = @TypeOf(fields);
        const fields_info = @typeInfo(Fields);
        if (fields_info == .@"struct") {
            inline for (fields_info.@"struct".fields) |f| {
                try w.writeAll(",\"");
                try w.writeAll(f.name);
                try w.writeAll("\":");
                try writeJsonValue(w, @field(fields, f.name));
            }
        }

        // Fatal hint
        if (level == .fatal) {
            try w.writeAll(",\"_hint\":\"stack_trace_recommended\"");
        }

        try w.writeAll("}\n");
    }

    fn writeTimestamp(w: anytype) !void {
        const epoch_seconds = std.time.timestamp();
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch_seconds) };
        const day = es.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();

        try std.fmt.format(w, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        });
    }

    fn writeJsonEscaped(w: anytype, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            }
        }
    }

    fn writeJsonValue(w: anytype, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .int, .comptime_int => try std.fmt.format(w, "{d}", .{value}),
            .float, .comptime_float => try std.fmt.format(w, "{d:.6}", .{value}),
            .bool => try w.writeAll(if (value) "true" else "false"),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try w.writeByte('"');
                    try writeJsonEscaped(w, value);
                    try w.writeByte('"');
                } else {
                    try std.fmt.format(w, "\"{any}\"", .{value});
                }
            },
            .optional => {
                if (value) |v| {
                    try writeJsonValue(w, v);
                } else {
                    try w.writeAll("null");
                }
            },
            .@"enum" => {
                try w.writeByte('"');
                try w.writeAll(@tagName(value));
                try w.writeByte('"');
            },
            else => try std.fmt.format(w, "\"{any}\"", .{value}),
        }
    }

    // ── Writer helpers ────────────────────────────────────────────

    /// Build a Writer backed by stderr.
    pub fn stderrWriter() Writer {
        const S = struct {
            var dummy: u8 = 0;
            fn write(ctx: *anyopaque, bytes: []const u8) void {
                _ = ctx;
                std.io.getStdErr().writeAll(bytes) catch {};
            }
        };
        return .{ .context = @ptrCast(&S.dummy), .writeFn = &S.write };
    }

    /// Build a Writer backed by an ArrayList(u8) — useful for testing.
    pub fn arrayListWriter(list: *std.ArrayList(u8)) Writer {
        const Gen = struct {
            fn write(ctx: *anyopaque, bytes: []const u8) void {
                const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                l.appendSlice(bytes) catch {};
            }
        };
        return .{ .context = @ptrCast(list), .writeFn = &Gen.write };
    }
};

// ── Global logger ────────────────────────────────────────────────

pub var global: Logger = undefined;
var global_initialized: bool = false;

/// Initialize the global logger (call once at startup).
pub fn initGlobal(allocator: std.mem.Allocator, level: config.LogLevel, output: Logger.Writer) void {
    global = Logger.init(allocator, level, output);
    global_initialized = true;
}

/// Initialize global logger with stderr output.
pub fn init() void {
    global = Logger.init(std.heap.page_allocator, .info, Logger.stderrWriter());
    global_initialized = true;
}

pub fn deinitGlobal() void {
    if (global_initialized) {
        global.deinit();
        global_initialized = false;
    }
}

// ── Module-level convenience (free functions on the global) ──────

pub fn trace(msg: []const u8, fields: anytype) void {
    if (global_initialized) global.trace(msg, fields);
}
pub fn debug(msg: []const u8, fields: anytype) void {
    if (global_initialized) global.debug(msg, fields);
}
pub fn info(msg: []const u8, fields: anytype) void {
    if (global_initialized) global.info(msg, fields);
}
pub fn warn(msg: []const u8, fields: anytype) void {
    if (global_initialized) global.warn(msg, fields);
}
pub fn err(msg: []const u8, fields: anytype) void {
    if (global_initialized) global.err(msg, fields);
}
pub fn fatal(msg: []const u8, fields: anytype) void {
    if (global_initialized) global.fatal(msg, fields);
}

// ══════════════════════════════════════════════════════════════════
//  Tests
// ══════════════════════════════════════════════════════════════════

fn parseJsonField(json: []const u8, comptime key: []const u8) ?[]const u8 {
    // Tiny purpose-built helper: finds `"key":` and returns the raw value token.
    const needle_quoted = "\"" ++ key ++ "\":";
    const start_idx = std.mem.indexOf(u8, json, needle_quoted) orelse return null;
    const after_colon = start_idx + needle_quoted.len;
    if (after_colon >= json.len) return null;
    if (json[after_colon] == '"') {
        // String value — find closing quote (not escaped).
        const str_start = after_colon + 1;
        var i: usize = str_start;
        while (i < json.len) : (i += 1) {
            if (json[i] == '\\') {
                i += 1; // skip escaped char
                continue;
            }
            if (json[i] == '"') break;
        }
        return json[str_start..i];
    }
    // Non-string value — read until comma, brace, or newline.
    const val_start = after_colon;
    var i: usize = val_start;
    while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != '\n') : (i += 1) {}
    return json[val_start..i];
}

test "log entry produces valid JSON" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var logger = Logger.init(allocator, .trace, Logger.arrayListWriter(&buf));

    logger.info("hello world", .{});

    const output = buf.items;
    // Must start with '{' and end with '}\n'
    try std.testing.expect(output.len > 2);
    try std.testing.expectEqual(output[0], '{');
    try std.testing.expectEqual(output[output.len - 2], '}');
    try std.testing.expectEqual(output[output.len - 1], '\n');

    // Check required fields present
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ts\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"msg\":\"hello world\"") != null);
}

test "log level filtering works" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var logger = Logger.init(allocator, .warn, Logger.arrayListWriter(&buf));

    logger.debug("should not appear", .{});
    logger.info("should not appear either", .{});
    try std.testing.expectEqual(buf.items.len, 0);

    logger.warn("this should appear", .{});
    try std.testing.expect(buf.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"level\":\"warn\"") != null);
}

test "scoped logger sets module name" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var logger = Logger.init(allocator, .trace, Logger.arrayListWriter(&buf));
    var consensus_log = logger.scoped("consensus");

    consensus_log.info("round started", .{});

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "\"module\":\"consensus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"msg\":\"round started\"") != null);
}

test "structured fields appear in output" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var logger = Logger.init(allocator, .trace, Logger.arrayListWriter(&buf));

    logger.info("ledger closed", .{ .seq = @as(u64, 12345), .duration_ms = @as(u64, 3200) });

    const output = buf.items;
    const seq_val = parseJsonField(output, "seq");
    try std.testing.expect(seq_val != null);
    try std.testing.expect(std.mem.eql(u8, seq_val.?, "12345"));

    const dur_val = parseJsonField(output, "duration_ms");
    try std.testing.expect(dur_val != null);
    try std.testing.expect(std.mem.eql(u8, dur_val.?, "3200"));
}

test "fatal level includes stack trace hint" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var logger = Logger.init(allocator, .trace, Logger.arrayListWriter(&buf));

    logger.fatal("invariant violated", .{});

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"fatal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"_hint\":\"stack_trace_recommended\"") != null);
}

test "setLevel changes filtering at runtime" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var logger = Logger.init(allocator, .info, Logger.arrayListWriter(&buf));

    logger.debug("invisible", .{});
    try std.testing.expectEqual(buf.items.len, 0);

    logger.setLevel(.debug);
    logger.debug("now visible", .{});
    try std.testing.expect(buf.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"level\":\"debug\"") != null);
}

test "logger initialization" {
    // Backward-compat: basic smoke test matching old test name.
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var logger = Logger.init(allocator, .info, Logger.arrayListWriter(&buf));
    defer logger.deinit();

    logger.info("Test info message", .{});
    try std.testing.expect(buf.items.len > 0);
}

test "log levels" {
    // Backward-compat: ordering preserved from old test.
    try std.testing.expect(@intFromEnum(config.LogLevel.debug) < @intFromEnum(config.LogLevel.info));
    try std.testing.expect(@intFromEnum(config.LogLevel.info) < @intFromEnum(config.LogLevel.warn));
    try std.testing.expect(@intFromEnum(config.LogLevel.warn) < @intFromEnum(config.LogLevel.@"error"));
}
