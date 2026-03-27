const std = @import("std");
const crypto = @import("crypto.zig");
const canonical_tx = @import("canonical_tx.zig");
const canonical = @import("canonical.zig");
const base58 = @import("base58.zig");
const ripemd160 = @import("ripemd160.zig");

/// Number of warm-up iterations before each benchmark.
const WARMUP_ITERS: usize = 100;

/// Maximum wall-clock time per benchmark (nanoseconds). 1 second.
const MAX_NS: u64 = 1_000_000_000;

/// Maximum iterations per benchmark (cap to avoid runaway loops).
const MAX_ITERS: usize = 10_000;

// ── Benchmark harness ──

const BenchResult = struct {
    name: []const u8,
    ops: u64,
    total_ns: u64,
    throughput_label: ?[]const u8, // e.g. "MB/sec"
    throughput_value: ?f64,
};

fn formatNumber(buf: []u8, n: u64) []const u8 {
    // Format an integer with comma separators.
    var raw_buf: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&raw_buf, "{d}", .{n}) catch return "???";
    if (raw.len <= 3) {
        @memcpy(buf[0..raw.len], raw);
        return buf[0..raw.len];
    }
    // Insert commas
    var pos: usize = 0;
    const first_group = raw.len % 3;
    if (first_group > 0) {
        @memcpy(buf[pos .. pos + first_group], raw[0..first_group]);
        pos += first_group;
    }
    var i: usize = first_group;
    while (i < raw.len) {
        if (pos > 0) {
            buf[pos] = ',';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + 3], raw[i .. i + 3]);
        pos += 3;
        i += 3;
    }
    return buf[0..pos];
}

fn printTable(results: []const BenchResult) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("\n", .{}) catch {};

    // Header
    stdout.print("{s: <30} {s: >12} {s: >10}", .{ "Benchmark", "ops/sec", "ns/op" }) catch {};
    // Check if any result has throughput
    var has_throughput = false;
    for (results) |r| {
        if (r.throughput_label != null) {
            has_throughput = true;
            break;
        }
    }
    if (has_throughput) {
        stdout.print("  {s: >14}", .{"throughput"}) catch {};
    }
    stdout.print("\n", .{}) catch {};

    // Separator using plain ASCII dashes
    const sep_name = "------------------------------";
    const sep_ops = "------------";
    const sep_ns = "----------";
    const sep_tp = "--------------";
    stdout.print("{s} {s} {s}", .{ sep_name, sep_ops, sep_ns }) catch {};
    if (has_throughput) {
        stdout.print("  {s}", .{sep_tp}) catch {};
    }
    stdout.print("\n", .{}) catch {};

    // Rows
    for (results) |r| {
        const ops_per_sec: u64 = if (r.total_ns > 0)
            r.ops * 1_000_000_000 / r.total_ns
        else
            0;
        const ns_per_op: u64 = if (r.ops > 0) r.total_ns / r.ops else 0;

        var ops_buf: [48]u8 = undefined;
        var nsop_buf: [48]u8 = undefined;
        const ops_str = formatNumber(&ops_buf, ops_per_sec);
        const nsop_str = formatNumber(&nsop_buf, ns_per_op);

        stdout.print("{s: <30} {s: >12} {s: >10}", .{ r.name, ops_str, nsop_str }) catch {};
        if (has_throughput) {
            if (r.throughput_label) |label| {
                var tp_buf: [32]u8 = undefined;
                const tp_str = std.fmt.bufPrint(&tp_buf, "{d:.1} {s}", .{ r.throughput_value.?, label }) catch "???";
                stdout.print("  {s: >14}", .{tp_str}) catch {};
            } else {
                stdout.print("  {s: >14}", .{""}) catch {};
            }
        }
        stdout.print("\n", .{}) catch {};
    }
    stdout.print("\n", .{}) catch {};
}

// ── Individual benchmarks ──

fn benchSha512Half() BenchResult {
    const data: [32]u8 = [_]u8{0xAB} ** 32;

    // Warm up
    for (0..WARMUP_ITERS) |_| {
        _ = crypto.Hash.sha512Half(&data);
    }

    var timer = std.time.Timer.start() catch @panic("timer");
    var ops: u64 = 0;
    while (ops < MAX_ITERS) : (ops += 1) {
        _ = crypto.Hash.sha512Half(&data);
        if (timer.read() >= MAX_NS) break;
    }
    const elapsed = timer.read();

    const bytes_total: f64 = @as(f64, @floatFromInt(ops)) * 32.0;
    const seconds: f64 = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;
    const mb_per_sec: f64 = bytes_total / (1024.0 * 1024.0) / seconds;

    return .{
        .name = "SHA-512 Half (32B)",
        .ops = ops,
        .total_ns = elapsed,
        .throughput_label = "MB/sec",
        .throughput_value = mb_per_sec,
    };
}

fn benchRipemd160() BenchResult {
    const data: [32]u8 = [_]u8{0xCD} ** 32;
    var out: [20]u8 = undefined;

    // Warm up
    for (0..WARMUP_ITERS) |_| {
        ripemd160.hash(&data, &out);
    }

    var timer = std.time.Timer.start() catch @panic("timer");
    var ops: u64 = 0;
    while (ops < MAX_ITERS) : (ops += 1) {
        ripemd160.hash(&data, &out);
        if (timer.read() >= MAX_NS) break;
    }
    const elapsed = timer.read();

    const bytes_total: f64 = @as(f64, @floatFromInt(ops)) * 32.0;
    const seconds: f64 = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;
    const mb_per_sec: f64 = bytes_total / (1024.0 * 1024.0) / seconds;

    return .{
        .name = "RIPEMD-160 (32B)",
        .ops = ops,
        .total_ns = elapsed,
        .throughput_label = "MB/sec",
        .throughput_value = mb_per_sec,
    };
}

fn benchBase58Encode(allocator: std.mem.Allocator) BenchResult {
    // Encode a typical 25-byte payload (version + 20-byte account ID + 4-byte checksum)
    const data: [25]u8 = [_]u8{ 0x00 } ++ [_]u8{0xAB} ** 20 ++ [_]u8{ 0x01, 0x02, 0x03, 0x04 };

    // Warm up
    for (0..WARMUP_ITERS) |_| {
        const enc = base58.Base58.encode(allocator, &data) catch continue;
        allocator.free(enc);
    }

    var timer = std.time.Timer.start() catch @panic("timer");
    var ops: u64 = 0;
    while (ops < MAX_ITERS) : (ops += 1) {
        const enc = base58.Base58.encode(allocator, &data) catch break;
        allocator.free(enc);
        if (timer.read() >= MAX_NS) break;
    }
    const elapsed = timer.read();

    return .{
        .name = "Base58 Encode",
        .ops = ops,
        .total_ns = elapsed,
        .throughput_label = null,
        .throughput_value = null,
    };
}

fn benchBase58Decode(allocator: std.mem.Allocator) BenchResult {
    // Pre-encode a payload to have a valid Base58 string
    const data: [25]u8 = [_]u8{ 0x00 } ++ [_]u8{0xAB} ** 20 ++ [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const encoded = base58.Base58.encode(allocator, &data) catch return .{
        .name = "Base58 Decode",
        .ops = 0,
        .total_ns = 1,
        .throughput_label = null,
        .throughput_value = null,
    };
    defer allocator.free(encoded);

    // Warm up
    for (0..WARMUP_ITERS) |_| {
        const dec = base58.Base58.decode(allocator, encoded) catch continue;
        allocator.free(dec);
    }

    var timer = std.time.Timer.start() catch @panic("timer");
    var ops: u64 = 0;
    while (ops < MAX_ITERS) : (ops += 1) {
        const dec = base58.Base58.decode(allocator, encoded) catch break;
        allocator.free(dec);
        if (timer.read() >= MAX_NS) break;
    }
    const elapsed = timer.read();

    return .{
        .name = "Base58 Decode",
        .ops = ops,
        .total_ns = elapsed,
        .throughput_label = null,
        .throughput_value = null,
    };
}

fn benchPaymentSerialize(allocator: std.mem.Allocator) BenchResult {
    const tx = canonical_tx.TransactionJSON{
        .TransactionType = "Payment",
        .Sequence = 1,
        .Fee = "12",
        .Flags = 2147483648,
        .Amount = "1000000",
    };

    // Warm up
    for (0..WARMUP_ITERS) |_| {
        var ser = canonical_tx.CanonicalTransactionSerializer.init(allocator) catch continue;
        defer ser.deinit();
        const s = ser.serializeForSigning(tx) catch continue;
        allocator.free(s);
    }

    var timer = std.time.Timer.start() catch @panic("timer");
    var ops: u64 = 0;
    while (ops < MAX_ITERS) : (ops += 1) {
        var ser = canonical_tx.CanonicalTransactionSerializer.init(allocator) catch break;
        defer ser.deinit();
        const s = ser.serializeForSigning(tx) catch break;
        allocator.free(s);
        if (timer.read() >= MAX_NS) break;
    }
    const elapsed = timer.read();

    return .{
        .name = "Payment Serialize",
        .ops = ops,
        .total_ns = elapsed,
        .throughput_label = null,
        .throughput_value = null,
    };
}

fn benchPaymentSerializeAndHash(allocator: std.mem.Allocator) BenchResult {
    const tx = canonical_tx.TransactionJSON{
        .TransactionType = "Payment",
        .Sequence = 1,
        .Fee = "12",
        .Flags = 2147483648,
        .Amount = "1000000",
    };

    // Warm up
    for (0..WARMUP_ITERS) |_| {
        var ser = canonical_tx.CanonicalTransactionSerializer.init(allocator) catch continue;
        defer ser.deinit();
        const s = ser.serializeForSigning(tx) catch continue;
        defer allocator.free(s);
        _ = canonical_tx.CanonicalTransactionSerializer.calculateBodyHash(s);
    }

    var timer = std.time.Timer.start() catch @panic("timer");
    var ops: u64 = 0;
    while (ops < MAX_ITERS) : (ops += 1) {
        var ser = canonical_tx.CanonicalTransactionSerializer.init(allocator) catch break;
        defer ser.deinit();
        const s = ser.serializeForSigning(tx) catch break;
        defer allocator.free(s);
        _ = canonical_tx.CanonicalTransactionSerializer.calculateBodyHash(s);
        if (timer.read() >= MAX_NS) break;
    }
    const elapsed = timer.read();

    return .{
        .name = "Payment Serialize+Hash",
        .ops = ops,
        .total_ns = elapsed,
        .throughput_label = null,
        .throughput_value = null,
    };
}

// ── Public entry point ──

pub fn run(allocator: std.mem.Allocator) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("rippled-zig benchmark suite\n", .{}) catch {};
    stdout.print("Warming up {d} iterations, then running each benchmark for up to 1 s or {d} iterations.\n", .{ WARMUP_ITERS, MAX_ITERS }) catch {};

    var results: [6]BenchResult = undefined;

    results[0] = benchSha512Half();
    results[1] = benchRipemd160();
    results[2] = benchBase58Encode(allocator);
    results[3] = benchBase58Decode(allocator);
    results[4] = benchPaymentSerialize(allocator);
    results[5] = benchPaymentSerializeAndHash(allocator);

    printTable(&results);
}

// ── Tests ──

test "benchmark smoke test" {
    // Just verify each benchmark can execute a few iterations without crashing.
    const allocator = std.testing.allocator;

    _ = benchSha512Half();
    _ = benchRipemd160();
    _ = benchBase58Encode(allocator);
    _ = benchBase58Decode(allocator);
    _ = benchPaymentSerialize(allocator);
    _ = benchPaymentSerializeAndHash(allocator);
}
