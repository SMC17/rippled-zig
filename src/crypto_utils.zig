const std = @import("std");

/// Constant-time utilities for cryptographic operations.
///
/// All comparison and zeroing functions in this module execute in time
/// independent of the data values, preventing timing side-channel attacks.
/// Constant-time comparison of two byte slices.
/// Returns true if and only if the slices are equal, without
/// short-circuiting on the first differing byte.
pub fn timingSafeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

/// Constant-time comparison of fixed-size arrays.
pub fn timingSafeEqualFixed(comptime N: usize, a: *const [N]u8, b: *const [N]u8) bool {
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

/// Securely zero a buffer to prevent key material from lingering in memory.
/// Uses volatile writes that the compiler cannot optimize away.
pub fn secureZero(buf: []u8) void {
    // @memset with volatile semantics — Zig's @memset on a mutable slice
    // is not guaranteed to be non-optimizable, so we use a volatile pointer
    for (buf) |*byte| {
        @as(*volatile u8, @ptrCast(byte)).* = 0;
    }
}

/// Securely zero a fixed-size array.
pub fn secureZeroFixed(comptime N: usize, buf: *[N]u8) void {
    for (buf) |*byte| {
        @as(*volatile u8, @ptrCast(byte)).* = 0;
    }
}

/// Constant-time select: returns a if condition is true, b otherwise.
/// `condition` must be 0 or 1.
pub fn constantTimeSelect(comptime T: type, condition: u1, a: T, b: T) T {
    const mask = @as(T, 0) -% @as(T, condition);
    return (a & mask) | (b & ~mask);
}

/// Check if a byte slice is all zeros in constant time.
pub fn isZero(buf: []const u8) bool {
    var acc: u8 = 0;
    for (buf) |byte| {
        acc |= byte;
    }
    return acc == 0;
}

// ── Tests ──

test "timingSafeEqual: identical slices" {
    const a = "hello world";
    const b = "hello world";
    try std.testing.expect(timingSafeEqual(a, b));
}

test "timingSafeEqual: different slices" {
    const a = "hello world";
    const b = "hello warld";
    try std.testing.expect(!timingSafeEqual(a, b));
}

test "timingSafeEqual: different lengths" {
    const a = "hello";
    const b = "hello world";
    try std.testing.expect(!timingSafeEqual(a, b));
}

test "timingSafeEqualFixed: 32-byte hashes" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    @memset(&a, 0xAB);
    @memset(&b, 0xAB);
    try std.testing.expect(timingSafeEqualFixed(32, &a, &b));
    b[31] = 0x00;
    try std.testing.expect(!timingSafeEqualFixed(32, &a, &b));
}

test "secureZero: clears buffer" {
    var buf = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    secureZero(&buf);
    for (buf) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "isZero: all zeros" {
    const zeros = [_]u8{0} ** 32;
    try std.testing.expect(isZero(&zeros));
}

test "isZero: non-zero" {
    var buf = [_]u8{0} ** 32;
    buf[15] = 1;
    try std.testing.expect(!isZero(&buf));
}

test "constantTimeSelect" {
    try std.testing.expectEqual(@as(u8, 42), constantTimeSelect(u8, 1, 42, 99));
    try std.testing.expectEqual(@as(u8, 99), constantTimeSelect(u8, 0, 42, 99));
}
