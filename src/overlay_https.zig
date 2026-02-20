//! XRPL/2.0 overlay handshake over HTTPS
//! Real rippled: 1) TLS connect to port 51235, 2) HTTP Upgrade to XRPL/2.0, 3) binary protocol
//! For rippled-zig to rippled-zig: TCP + upgrade headers (no TLS) works with our custom peers.

const std = @import("std");

/// TLS-wrapped stream for rippled peer port (self-signed certs)
pub const TlsStream = struct {
    client: std.crypto.tls.Client,
    underlying: std.net.Stream,

    pub fn read(self: *TlsStream, buf: []u8) !usize {
        return self.client.read(&self.client, self.underlying, buf);
    }

    pub fn write(self: *TlsStream, data: []const u8) !void {
        return self.client.writeAll(&self.client, self.underlying, data);
    }

    pub fn readAll(self: *TlsStream, buf: []u8) !usize {
        return self.client.readAll(&self.client, self.underlying, buf);
    }

    pub fn close(self: *TlsStream) void {
        self.underlying.close();
    }
};

/// Unified stream: raw TCP or TLS (for peer protocol)
pub const PeerStream = union(enum) {
    raw: std.net.Stream,
    tls: TlsStream,

    pub fn read(self: *PeerStream, buf: []u8) !usize {
        return switch (self.*) {
            .raw => |*s| s.read(buf),
            .tls => |*s| s.read(buf),
        };
    }

    pub fn write(self: *PeerStream, data: []const u8) !void {
        return switch (self.*) {
            .raw => |*s| s.write(data),
            .tls => |*s| s.write(data),
        };
    }

    pub fn readAll(self: *PeerStream, buf: []u8) !usize {
        return switch (self.*) {
            .raw => |*s| s.readAll(buf),
            .tls => |*s| s.readAll(buf),
        };
    }

    pub fn close(self: *PeerStream) void {
        switch (self.*) {
            .raw => |*s| s.close(),
            .tls => |*s| s.close(),
        }
    }
};

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
/// For real rippled: use connectWithTlsAndUpgrade instead.
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

/// Connect via TLS then HTTP upgrade (for real rippled; uses self-signed cert acceptance)
pub fn connectWithTlsAndUpgrade(allocator: std.mem.Allocator, host: []const u8, port: u16) !TlsStream {
    var stream = try std.net.tcpConnectToHost(allocator, host, port);
    errdefer stream.close();

    const opts: std.crypto.tls.Client.Options = .{
        .host = .{ .explicit = host },
        .ca = .self_signed, // rippled uses self-signed certs on peer port
    };

    var client = try std.crypto.tls.Client.init(stream, opts);

    const req = try buildUpgradeRequest(allocator, host, port);
    defer allocator.free(req);
    try client.writeAll(&client, stream, req);

    var buf: [512]u8 = undefined;
    const n = try client.read(&client, stream, &buf);
    if (n == 0) return error.ConnectionClosed;
    if (!parseUpgradeResponse(buf[0..n])) {
        stream.close();
        return error.UpgradeRejected;
    }

    return TlsStream{ .client = client, .underlying = stream };
}

test "overlay upgrade request format" {
    const allocator = std.testing.allocator;
    const req = try buildUpgradeRequest(allocator, "s.altnet.rippletest.net", 51235);
    defer allocator.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "Upgrade: XRPL/2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: s.altnet.rippletest.net:51235") != null);
}
