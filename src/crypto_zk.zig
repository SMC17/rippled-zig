//! ZK / post-quantum signature experimental stubs
//! SPHINCS+ and ZK circuits require external libraries.
//! Kyber is in stdlib (see crypto_pqc.zig). This module documents intent.

const std = @import("std");

/// SPHINCS+ is a stateless hash-based PQC signature scheme (NIST selected).
/// Zig stdlib does not include it; add sphincs or similar when needed.
pub const SphincsPlusStatus = enum {
    not_implemented, // Would use external: sphincs-zig or NIST reference
};

/// ZK circuits for privacy/scalability - research direction.
/// Would integrate zk-SNARKs or similar; requires circuit compiler (circom, etc).
pub const ZkCircuitStatus = enum {
    not_implemented,
};

pub fn status() void {
    _ = SphincsPlusStatus.not_implemented;
    _ = ZkCircuitStatus.not_implemented;
}

test "zk status" {
    status();
}
