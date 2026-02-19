//! XRPL/2.0 overlay handshake over HTTPS
//! Real rippled: 1) TLS connect to port 51235, 2) HTTP Upgrade to XRPL/2.0, 3) binary protocol
//! For rippled-zig to rippled-zig: TCP + upgrade headers (no TLS) works with our custom peers.

const std = @import("std");

/// Build HTTP Upgrade request for XRPL/2.0 protocol
/// RFC 7230: "Upgrade: XRPL/2.0" plus "Connection: Upgrade"
pub fn buildUpgradeRequest(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\GET / HTTP/1.1
        \\Host: {s}:{d}
        \\Upgrade: XRPL/2.0
        \\Connection: Upgrade
        \\Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
        \\Sec-WebSocket-Version: 13
        \\
        \\
    , .{ host, port });
}

/// Parse HTTP response for 101 Switching Protocols
pub fn parseUpgradeResponse(data: []const u8) !bool {
    if (data.len < 12) return false;
    // Expect "HTTP/1.1 101" or "HTTP/1.0 101"
    if (std.mem.indexOf(u8, data[0..@min(15, data.len)], "101") == null) return false;
    return std.mem.indexOf(u8, data, "Upgrade: XRPL") != null or
        std.mem.indexOf(u8, data, "upgrade: xrpl") != null;
}

/// Connect via TCP and perform XRPL/2.0 upgrade (no TLS - for rippled-zig peers)
/// For real rippled: wrap stream in TLS first; rippled uses self-signed certs on peer port.
pub fn connectWithUpgrade(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Stream {
    var stream = try std.net.tcpConnectToHost(allocator, host, port);

    const req = try buildUpgradeRequest(allocator, host, port);
    defer allocator.free(req);
    _ = try stream.write(req);

    var buf: [512]u8 = undefined;
    const n = try stream.read(&buf);
    if (n == 0) return error.ConnectionClosed;
    if (!parseUpgradeResponse(buf[0..n])) {
        stream.close();
        return error.UpgradeRejected;
    }
    return stream;
}

test "overlay upgrade request format" {
    const allocator = std.testing.allocator;
    const req = try buildUpgradeRequest(allocator, "s.altnet.rippletest.net", 51235);
    defer allocator.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "Upgrade: XRPL/2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: s.altnet.rippletest.net:51235") != null);
}
