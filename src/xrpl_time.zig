const std = @import("std");

/// XRPL uses "Ripple Epoch" — seconds since January 1, 2000 00:00:00 UTC.
/// Unix epoch offset: 946684800 seconds between Unix epoch (1970) and Ripple epoch (2000).
pub const RIPPLE_EPOCH_OFFSET: i64 = 946684800;

/// Convert Unix timestamp to Ripple timestamp
pub fn unixToRipple(unix_time: i64) i64 {
    return unix_time - RIPPLE_EPOCH_OFFSET;
}

/// Convert Ripple timestamp to Unix timestamp
pub fn rippleToUnix(ripple_time: i64) i64 {
    return ripple_time + RIPPLE_EPOCH_OFFSET;
}

/// Get current time as Ripple timestamp
pub fn now() i64 {
    const unix_time = std.time.timestamp();
    return unixToRipple(unix_time);
}

/// Format a Ripple timestamp as ISO 8601 string (YYYY-MM-DDTHH:MM:SSZ)
pub fn formatISO(ripple_time: i64, buf: []u8) ![]const u8 {
    const unix_time = rippleToUnix(ripple_time);
    const epoch_secs: u64 = @intCast(unix_time);
    const epoch_day = epoch_secs / 86400;
    const day_secs = epoch_secs % 86400;
    const hours = day_secs / 3600;
    const minutes = (day_secs % 3600) / 60;
    const seconds = day_secs % 60;

    // Civil date from epoch day (algorithm from Howard Hinnant)
    const z = epoch_day + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m_raw = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m_raw <= 2) y + 1 else y;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year,
        m_raw,
        d,
        hours,
        minutes,
        seconds,
    });
}

/// Check if a Ripple timestamp represents a time in the past
pub fn isExpired(ripple_time: i64) bool {
    return ripple_time < now();
}

/// Maximum valid Ripple timestamp (year 2136 approximately)
pub const MAX_RIPPLE_TIME: i64 = 4294967295; // u32 max

/// Validate a Ripple timestamp is in reasonable range
pub fn isValid(ripple_time: i64) bool {
    return ripple_time >= 0 and ripple_time <= MAX_RIPPLE_TIME;
}

// ── Tests ──

test "unix to ripple conversion" {
    // Jan 1, 2000 00:00:00 UTC = Unix 946684800 = Ripple 0
    try std.testing.expectEqual(@as(i64, 0), unixToRipple(946684800));

    // Jan 1, 2024 00:00:00 UTC = Unix 1704067200 = Ripple 757382400
    try std.testing.expectEqual(@as(i64, 757382400), unixToRipple(1704067200));
    std.debug.print("[PASS] Unix to Ripple time conversion\n", .{});
}

test "ripple to unix conversion" {
    try std.testing.expectEqual(@as(i64, 946684800), rippleToUnix(0));
    try std.testing.expectEqual(@as(i64, 1704067200), rippleToUnix(757382400));
    std.debug.print("[PASS] Ripple to Unix time conversion\n", .{});
}

test "round trip conversion" {
    const unix_time: i64 = 1700000000;
    try std.testing.expectEqual(unix_time, rippleToUnix(unixToRipple(unix_time)));
    std.debug.print("[PASS] Round-trip time conversion\n", .{});
}

test "format ISO 8601" {
    var buf: [32]u8 = undefined;
    // Ripple time 0 = Jan 1, 2000 00:00:00 UTC
    const formatted = try formatISO(0, &buf);
    try std.testing.expectEqualStrings("2000-01-01T00:00:00Z", formatted);
    std.debug.print("[PASS] ISO 8601 formatting: {s}\n", .{formatted});
}

test "validity check" {
    try std.testing.expect(isValid(0));
    try std.testing.expect(isValid(757382400));
    try std.testing.expect(!isValid(-1));
    std.debug.print("[PASS] Validity checks\n", .{});
}
