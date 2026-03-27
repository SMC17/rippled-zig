//! rippled-zig public API surface
//!
//! v1 Toolkit: canonical encoding, signing, verification, RPC parsing.
//! Experimental node subsystems are NOT exposed here.

// ── Encoding & Serialization ──
pub const canonical_tx = @import("canonical_tx.zig");
pub const canonical = @import("canonical.zig");
pub const serialization = @import("serialization.zig");

// ── Cryptography ──
pub const crypto = @import("crypto.zig");
pub const secp256k1 = @import("secp256k1.zig");
pub const secp256k1_binding = @import("secp256k1_binding.zig");
pub const ripemd160 = @import("ripemd160.zig");

// ── Address Encoding ──
pub const base58 = @import("base58.zig");

// ── Transaction Types ──
pub const types = @import("types.zig");
pub const transaction = @import("transaction.zig");

// ── RPC Parsing & Conformance ──
pub const rpc = @import("rpc.zig");
pub const rpc_methods = @import("rpc_methods.zig");
pub const rpc_format = @import("rpc_format.zig");
pub const rpc_complete = @import("rpc_complete.zig");

// ── Conformance & Verification ──
pub const parity_check = @import("parity_check.zig");
pub const determinism_check = @import("determinism_check.zig");
pub const invariant_probe = @import("invariant_probe.zig");
pub const invariants = @import("invariants.zig");

// ── Protocol Kernel (WASM-compatible subset) ──
pub const protocol_kernel = @import("protocol_kernel.zig");
