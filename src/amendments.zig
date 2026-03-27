const std = @import("std");
const types = @import("types.zig");

/// Amendment System - Protocol upgrade mechanism
///
/// XRPL uses amendments to introduce new features and fix bugs
/// Validators vote on amendments, which activate when 80% approval for 2 weeks
pub const AmendmentManager = struct {
    allocator: std.mem.Allocator,
    amendments: std.StringHashMap(Amendment),
    enabled: std.StringHashMap(bool),

    pub fn init(allocator: std.mem.Allocator) !AmendmentManager {
        return AmendmentManager{
            .allocator = allocator,
            .amendments = std.StringHashMap(Amendment).init(allocator),
            .enabled = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *AmendmentManager) void {
        var it = self.amendments.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.amendments.deinit();
        var eit = self.enabled.iterator();
        while (eit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.enabled.deinit();
    }

    /// Register an amendment
    pub fn registerAmendment(self: *AmendmentManager, name: []const u8, amendment: Amendment) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        try self.amendments.put(owned_name, amendment);
    }

    /// Enable an amendment
    pub fn enableAmendment(self: *AmendmentManager, name: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        try self.enabled.put(owned_name, true);
    }

    /// Check if amendment is enabled
    pub fn isEnabled(self: *const AmendmentManager, name: []const u8) bool {
        return self.enabled.get(name) orelse false;
    }

    /// Get all enabled amendments
    pub fn getEnabled(self: *const AmendmentManager, allocator: std.mem.Allocator) ![][]const u8 {
        var list = try std.ArrayList([]const u8).initCapacity(allocator, self.enabled.count());
        errdefer list.deinit();

        var it = self.enabled.keyIterator();
        while (it.next()) |key| {
            try list.append(key.*);
        }

        return list.toOwnedSlice();
    }
};

/// Amendment definition
pub const Amendment = struct {
    id: [32]u8,
    name: []const u8,
    introduced: types.LedgerSequence,
    enabled: ?types.LedgerSequence = null,
    vetoed: bool = false,

    /// Check voting status
    pub fn getStatus(self: *const Amendment) AmendmentStatus {
        if (self.enabled != null) {
            return .enabled;
        } else if (self.vetoed) {
            return .vetoed;
        } else {
            return .pending;
        }
    }
};

pub const AmendmentStatus = enum {
    pending,
    enabled,
    vetoed,
};

/// Known XRPL amendments
pub const KnownAmendments = struct {
    // Multi-sign
    pub const MultiSign = "MultiSign";

    // Flow cross-currency
    pub const FlowCross = "FlowCross";

    // Payment Channels
    pub const PayChan = "PayChan";

    // Checks
    pub const Checks = "Checks";

    // Escrow
    pub const Escrow = "Escrow";

    // Fix bugs
    pub const Fix1368 = "fix1368";
    pub const Fix1373 = "fix1373";
    pub const Fix1513 = "fix1513";

    // NFTs
    pub const NonFungibleTokensV1 = "NonFungibleTokensV1_1";

    // AMM
    pub const AMM = "AMM";

    // Clawback
    pub const Clawback = "Clawback";
};

test "amendment manager" {
    const allocator = std.testing.allocator;
    var manager = try AmendmentManager.init(allocator);
    defer manager.deinit();

    // Register amendment
    const amendment = Amendment{
        .id = [_]u8{1} ** 32,
        .name = "TestAmendment",
        .introduced = 1000,
    };

    try manager.registerAmendment("TestAmendment", amendment);

    // Not enabled yet
    try std.testing.expect(!manager.isEnabled("TestAmendment"));

    // Enable it
    try manager.enableAmendment("TestAmendment");
    try std.testing.expect(manager.isEnabled("TestAmendment"));
}

test "amendment status" {
    const amendment = Amendment{
        .id = [_]u8{0} ** 32,
        .name = "Test",
        .introduced = 100,
    };

    try std.testing.expectEqual(AmendmentStatus.pending, amendment.getStatus());
}
