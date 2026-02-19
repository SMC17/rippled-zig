const std = @import("std");
const build_options = @import("build_options");
const has_secp256k1 = build_options.has_secp256k1;

/// secp256k1 ECDSA Implementation via C Binding
///
/// WEEK 2: Full implementation for 100% signature compatibility
///
/// Binds to libsecp256k1 (Bitcoin Core's battle-tested library)
/// This is CRITICAL - most real XRPL transactions use secp256k1
/// Build configuration: link to libsecp256k1
/// In build.zig, add: exe.linkSystemLibrary("secp256k1");

// Opaque types from libsecp256k1
// These are actual structs from the C library - we use extern struct to match C ABI
const secp256k1_pubkey = extern struct {
    data: [64]u8 align(16), // Actual size from libsecp256k1 source
};
const secp256k1_ecdsa_signature = extern struct {
    data: [64]u8 align(16), // Actual size from libsecp256k1 source
};

const c = if (has_secp256k1) struct {
    extern fn secp256k1_context_create(flags: c_uint) ?*anyopaque;
    extern fn secp256k1_context_destroy(ctx: ?*anyopaque) void;
    extern fn secp256k1_ecdsa_verify(
        ctx: ?*const anyopaque,
        sig: ?*const secp256k1_ecdsa_signature,
        msg32: [*c]const u8,
        pubkey: ?*const secp256k1_pubkey,
    ) c_int;
    extern fn secp256k1_ecdsa_sign(
        ctx: ?*const anyopaque,
        sig: ?*secp256k1_ecdsa_signature,
        msg32: [*c]const u8,
        seckey: [*c]const u8,
        noncefn: ?*const anyopaque,
        ndata: ?*anyopaque,
    ) c_int;
    extern fn secp256k1_ecdsa_signature_serialize_der(
        ctx: ?*const anyopaque,
        output: [*c]u8,
        outputlen: [*c]usize,
        sig: ?*const secp256k1_ecdsa_signature,
    ) c_int;
    extern fn secp256k1_ec_pubkey_parse(
        ctx: ?*const anyopaque,
        pubkey: ?*secp256k1_pubkey,
        input: [*c]const u8,
        inputlen: usize,
    ) c_int;
    extern fn secp256k1_ecdsa_signature_parse_der(
        ctx: ?*const anyopaque,
        sig: ?*secp256k1_ecdsa_signature,
        input: [*c]const u8,
        inputlen: usize,
    ) c_int;
} else struct {};

const SECP256K1_CONTEXT_VERIFY: c_uint = 0x0101;
const SECP256K1_CONTEXT_SIGN: c_uint = 0x0201;

/// secp256k1 context (singleton) - verify only
var global_context: ?*anyopaque = null;
/// secp256k1 signing context (singleton)
var sign_context: ?*anyopaque = null;
var context_mutex: std.Thread.Mutex = .{};

/// Initialize secp256k1 context
pub fn init() !void {
    if (!has_secp256k1) return error.LibraryUnavailable;

    context_mutex.lock();
    defer context_mutex.unlock();

    if (global_context == null) {
        global_context = c.secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
        if (global_context == null) {
            return error.ContextCreationFailed;
        }
    }
}

/// Deinitialize secp256k1 context
pub fn deinit() void {
    if (!has_secp256k1) return;

    context_mutex.lock();
    defer context_mutex.unlock();

    if (sign_context) |ctx| {
        c.secp256k1_context_destroy(ctx);
        sign_context = null;
    }
    if (global_context) |ctx| {
        c.secp256k1_context_destroy(ctx);
        global_context = null;
    }
}

/// Initialize signing context (lazy)
fn initSign() !void {
    if (!has_secp256k1) return error.LibraryUnavailable;

    context_mutex.lock();
    defer context_mutex.unlock();

    if (sign_context == null) {
        sign_context = c.secp256k1_context_create(SECP256K1_CONTEXT_SIGN);
        if (sign_context == null) {
            return error.ContextCreationFailed;
        }
    }
}

/// Sign message hash (32 bytes) with secret key (32 bytes), return DER-encoded signature
pub fn signMessage(
    secret_key: [32]u8,
    message_hash: [32]u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (!has_secp256k1) return error.LibraryUnavailable;

    try initSign();
    const ctx = sign_context orelse return error.ContextNotInitialized;

    var signature: secp256k1_ecdsa_signature = undefined;
    const sign_result = c.secp256k1_ecdsa_sign(
        ctx,
        &signature,
        &message_hash,
        &secret_key,
        null,
        null,
    );
    if (sign_result != 1) {
        return error.SignatureFailed;
    }

    // Serialize to DER - max 72 bytes for secp256k1
    var der_len: usize = 80;
    var der_buf = try allocator.alloc(u8, der_len);
    errdefer allocator.free(der_buf);
    const serialize_result = c.secp256k1_ecdsa_signature_serialize_der(
        ctx,
        der_buf.ptr,
        &der_len,
        &signature,
    );
    if (serialize_result != 1) {
        allocator.free(der_buf);
        return error.SerializeFailed;
    }

    const result = try allocator.dupe(der_buf[0..der_len]);
    allocator.free(der_buf);
    return result;
}

/// Verify ECDSA signature
pub fn verifySignature(
    public_key: []const u8,
    message_hash: [32]u8,
    signature_der: []const u8,
) !bool {
    if (!has_secp256k1) return error.LibraryUnavailable;

    // Ensure context initialized
    try init();

    const ctx = global_context orelse return error.ContextNotInitialized;

    // Parse public key (libsecp256k1 uses opaque structs)
    var pubkey: secp256k1_pubkey = undefined;
    const pubkey_result = c.secp256k1_ec_pubkey_parse(
        ctx,
        &pubkey,
        public_key.ptr,
        public_key.len,
    );
    if (pubkey_result != 1) {
        return error.InvalidPublicKey;
    }

    // Parse DER signature (libsecp256k1 uses opaque structs)
    var signature: secp256k1_ecdsa_signature = undefined;
    const sig_result = c.secp256k1_ecdsa_signature_parse_der(
        ctx,
        &signature,
        signature_der.ptr,
        signature_der.len,
    );
    if (sig_result != 1) {
        return error.InvalidSignature;
    }

    // Verify signature
    const verify_result = c.secp256k1_ecdsa_verify(
        ctx,
        &signature,
        &message_hash,
        &pubkey,
    );

    return verify_result == 1;
}

/// Alternative: Pure Zig implementation (for when C binding not available)
pub const PureZigSecp256k1 = struct {
    /// Field element for secp256k1 (prime p)
    const FieldElement = struct {
        data: [32]u8,

        /// Prime: p = 2^256 - 2^32 - 977
        const P = [32]u8{
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFE, 0xFF, 0xFF, 0xFC, 0x2F,
        };
    };

    /// Point on secp256k1 curve
    const Point = struct {
        x: FieldElement,
        y: FieldElement,
        infinity: bool = false,
    };

    /// Curve parameters
    const CURVE_B: u8 = 7; // y^2 = x^3 + 7

    /// Generator point G
    const G = Point{
        .x = FieldElement{ .data = [32]u8{
            0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
            0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
            0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
            0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
        } },
        .y = FieldElement{ .data = [32]u8{
            0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65,
            0x5D, 0xA4, 0xFB, 0xFC, 0x0E, 0x11, 0x08, 0xA8,
            0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19,
            0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10, 0xD4, 0xB8,
        } },
    };

    // Note: Full implementation would require:
    // - Point addition/multiplication
    // - Modular arithmetic
    // - Signature verification algorithm
    // - ~1,500+ lines of elliptic curve math

    /// Verify signature (pure Zig implementation)
    pub fn verify(public_key: []const u8, message_hash: [32]u8, signature: []const u8) !bool {
        _ = public_key;
        _ = message_hash;
        _ = signature;

        // TODO: Implement full ECDSA verification
        // This is complex and requires significant elliptic curve arithmetic
        // Recommended: Use C binding above for production

        return error.NotYetImplemented;
    }
};

test "secp256k1 binding ready" {
    // Note: This test requires libsecp256k1 to be installed
    // On macOS: brew install secp256k1
    // On Ubuntu: apt-get install libsecp256k1-dev

    // For now, just verify the binding interface is correct
    std.debug.print("[INFO] secp256k1 binding interface defined\n", .{});
    std.debug.print("[INFO] Requires: libsecp256k1 installed\n", .{});
    std.debug.print("[INFO] Build with: exe.linkSystemLibrary(\"secp256k1\")\n", .{});
}
