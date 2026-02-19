//! Modular architecture: logical package re-exports
//! Consensus | Ledger | API | Network

pub const consensus = @import("consensus.zig");
pub const ledger = @import("ledger.zig");
pub const types = @import("types.zig");

/// API/RPC surface
pub const rpc = @import("rpc.zig");
pub const rpc_methods = @import("rpc_methods.zig");

/// Network layer
pub const network = @import("network.zig");
pub const peer_protocol = @import("peer_protocol.zig");
pub const peer_wire = @import("peer_wire.zig");
pub const ledger_sync = @import("ledger_sync.zig");
pub const websocket = @import("websocket.zig");
