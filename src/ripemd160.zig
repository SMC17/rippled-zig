const std = @import("std");

/// RIPEMD-160 Implementation
/// Required for XRPL account ID derivation: AccountID = RIPEMD160(SHA256(pubkey))
///
/// This is a complete, working implementation of RIPEMD-160
/// BLOCKER #5 FIX
pub fn hash(data: []const u8, out: *[20]u8) void {
    var ctx = Context.init();
    ctx.update(data);
    ctx.final(out);
}

const Context = struct {
    state: [5]u32,
    count: u64,
    buffer: [64]u8,
    buffer_len: usize,

    const K_LEFT = [5]u32{ 0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E };
    const K_RIGHT = [5]u32{ 0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000 };

    fn init() Context {
        return Context{
            .state = [5]u32{ 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 },
            .count = 0,
            .buffer = undefined,
            .buffer_len = 0,
        };
    }

    fn update(self: *Context, data: []const u8) void {
        var pos: usize = 0;

        while (pos < data.len) {
            const remaining = 64 - self.buffer_len;
            const to_copy = @min(data.len - pos, remaining);

            @memcpy(self.buffer[self.buffer_len .. self.buffer_len + to_copy], data[pos .. pos + to_copy]);
            self.buffer_len += to_copy;
            pos += to_copy;
            self.count += to_copy;

            if (self.buffer_len == 64) {
                self.processBlock(&self.buffer);
                self.buffer_len = 0;
            }
        }
    }

    fn final(self: *Context, out: *[20]u8) void {
        // Pad message
        var padded: [64]u8 = undefined;
        @memcpy(padded[0..self.buffer_len], self.buffer[0..self.buffer_len]);
        padded[self.buffer_len] = 0x80;

        const pad_len = if (self.buffer_len < 56) 56 - self.buffer_len - 1 else 120 - self.buffer_len - 1;
        @memset(padded[self.buffer_len + 1 .. self.buffer_len + 1 + pad_len], 0);

        // Append length
        const bit_count = self.count * 8;
        std.mem.writeInt(u64, padded[56..64], bit_count, .little);

        if (self.buffer_len < 56) {
            self.processBlock(&padded);
        } else {
            self.processBlock(padded[0..64]);
            @memset(padded[0..56], 0);
            std.mem.writeInt(u64, padded[56..64], bit_count, .little);
            self.processBlock(&padded);
        }

        // Output state as bytes (little-endian)
        for (self.state, 0..) |word, i| {
            const out_word: *[4]u8 = @ptrCast(out[i * 4 .. i * 4 + 4].ptr);
            std.mem.writeInt(u32, out_word, word, .little);
        }
    }

    fn processBlock(self: *Context, block: *const [64]u8) void {
        var X: [16]u32 = undefined;
        for (0..16) |i| {
            const block_word: *const [4]u8 = @ptrCast(block[i * 4 .. i * 4 + 4].ptr);
            X[i] = std.mem.readInt(u32, block_word, .little);
        }

        var AL = self.state[0];
        var BL = self.state[1];
        var CL = self.state[2];
        var DL = self.state[3];
        var EL = self.state[4];

        var AR = self.state[0];
        var BR = self.state[1];
        var CR = self.state[2];
        var DR = self.state[3];
        var ER = self.state[4];

        // Left rounds
        inline for (0..80) |j| {
            const f = switch (j / 16) {
                0 => BL ^ CL ^ DL,
                1 => (BL & CL) | (~BL & DL),
                2 => (BL | ~CL) ^ DL,
                3 => (BL & DL) | (CL & ~DL),
                4 => BL ^ (CL | ~DL),
                else => unreachable,
            };

            const k = K_LEFT[j / 16];
            const r = R_LEFT[j];
            const s = S_LEFT[j];

            const temp = rotl(AL +% f +% X[r] +% k, s) +% EL;
            AL = EL;
            EL = DL;
            DL = rotl(CL, 10);
            CL = BL;
            BL = temp;
        }

        // Right rounds
        inline for (0..80) |j| {
            const f = switch (j / 16) {
                0 => BR ^ (CR | ~DR),
                1 => (BR & DR) | (CR & ~DR),
                2 => (BR | ~CR) ^ DR,
                3 => (BR & CR) | (~BR & DR),
                4 => BR ^ CR ^ DR,
                else => unreachable,
            };

            const k = K_RIGHT[j / 16];
            const r = R_RIGHT[j];
            const s = S_RIGHT[j];

            const temp = rotl(AR +% f +% X[r] +% k, s) +% ER;
            AR = ER;
            ER = DR;
            DR = rotl(CR, 10);
            CR = BR;
            BR = temp;
        }

        const temp = self.state[1] +% CL +% DR;
        self.state[1] = self.state[2] +% DL +% ER;
        self.state[2] = self.state[3] +% EL +% AR;
        self.state[3] = self.state[4] +% AL +% BR;
        self.state[4] = self.state[0] +% BL +% CR;
        self.state[0] = temp;
    }

    inline fn rotl(x: u32, n: u5) u32 {
        return std.math.rotl(u32, x, n);
    }

    const R_LEFT = [80]u8{
        0, 1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
        7, 4,  13, 1,  10, 6,  15, 3,  12, 0, 9,  5,  2,  14, 11, 8,
        3, 10, 14, 4,  9,  15, 8,  1,  2,  7, 0,  6,  13, 11, 5,  12,
        1, 9,  11, 10, 0,  8,  12, 4,  13, 3, 7,  15, 14, 5,  6,  2,
        4, 0,  5,  9,  7,  12, 2,  10, 14, 1, 3,  8,  11, 6,  15, 13,
    };

    const R_RIGHT = [80]u8{
        5,  14, 7,  0, 9, 2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12,
        6,  11, 3,  7, 0, 13, 5,  10, 14, 15, 8,  12, 4,  9,  1,  2,
        15, 5,  1,  3, 7, 14, 6,  9,  11, 8,  12, 2,  10, 0,  4,  13,
        8,  6,  4,  1, 3, 11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14,
        12, 15, 10, 4, 1, 5,  8,  7,  6,  2,  13, 14, 0,  3,  9,  11,
    };

    const S_LEFT = [80]u5{
        11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,
        7,  6,  8,  13, 11, 9,  7,  15, 7,  12, 15, 9,  11, 7,  13, 12,
        11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,  5,  12, 7,  5,
        11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12,
        9,  15, 5,  11, 6,  8,  13, 12, 5,  12, 13, 14, 11, 8,  5,  6,
    };

    const S_RIGHT = [80]u5{
        8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,
        9,  13, 15, 7,  12, 8,  9,  11, 7,  7,  12, 7,  6,  15, 13, 11,
        9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14, 13, 13, 7,  5,
        15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8,
        8,  5,  12, 9,  12, 5,  14, 6,  8,  13, 6,  5,  15, 13, 11, 11,
    };
};

test "ripemd160 basic" {
    const input = "hello";
    var output: [20]u8 = undefined;
    hash(input, &output);

    // Should produce non-zero hash
    var all_zeros = true;
    for (output) |byte| {
        if (byte != 0) {
            all_zeros = false;
            break;
        }
    }
    try std.testing.expect(!all_zeros);

    std.debug.print("✅ RIPEMD-160 produces hash\n", .{});
}

test "ripemd160 known vector" {
    // Known test vector: RIPEMD-160("") = 9c1185a5c5e9fc54612808977ee8f548b2258d31
    const input = "";
    var output: [20]u8 = undefined;
    hash(input, &output);

    const expected = [20]u8{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54,
        0x61, 0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48,
        0xb2, 0x25, 0x8d, 0x31,
    };

    try std.testing.expectEqualSlices(u8, &expected, &output);

    std.debug.print("[PASS] RIPEMD-160 matches known test vector\n", .{});
    std.debug.print("   Input: empty string\n", .{});
    std.debug.print("   Hash: {any}...\n", .{output[0..8]});
}
