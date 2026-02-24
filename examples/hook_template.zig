//! XRPL Hooks-compatible WASM template
//! Build with: zig build wasm
//!
//! XRPL Hooks expect:
//! - hook(reserved: u32) -> i64  (required entry point)
//! - cbak(what: u32) -> i64      (optional callback)
//!
//! Return codes: 0 = accept, 1 = rollback, etc. See XRPL Hooks specification.

/// Required hook entry point - called for each transaction.
/// Return 0 to accept, non-zero to reject/rollback.
pub export fn hook(reserved: u32) i64 {
    _ = reserved;
    // Minimal pass-through: accept all transactions
    return 0;
}

/// Optional callback for emitted transaction status
pub export fn cbak(what: u32) i64 {
    _ = what;
    return 0;
}
