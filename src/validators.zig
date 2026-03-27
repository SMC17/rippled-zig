const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const consensus = @import("consensus.zig");

/// Validator management and UNL (Unique Node List) loading
pub const ValidatorManager = struct {
    allocator: std.mem.Allocator,
    validators: std.ArrayList(Validator),
    unl: std.ArrayList(consensus.ValidatorInfo),

    pub fn init(allocator: std.mem.Allocator) !ValidatorManager {
        return ValidatorManager{
            .allocator = allocator,
            .validators = try std.ArrayList(Validator).initCapacity(allocator, 0),
            .unl = try std.ArrayList(consensus.ValidatorInfo).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *ValidatorManager) void {
        for (self.validators.items) |*validator| {
            self.allocator.free(validator.manifest_data);
        }
        self.validators.deinit();
        self.unl.deinit();
    }

    /// Load UNL from file or URL
    pub fn loadUNL(self: *ValidatorManager, source: []const u8) !void {
        // TODO: Implement actual UNL loading from vl.ripple.com or file
        _ = source;

        // For now, add some default testnet validators
        const default_validators = [_]consensus.ValidatorInfo{
            .{
                .public_key = [_]u8{1} ** 33,
                .node_id = [_]u8{10} ** 32,
                .is_trusted = true,
            },
            .{
                .public_key = [_]u8{2} ** 33,
                .node_id = [_]u8{20} ** 32,
                .is_trusted = true,
            },
            .{
                .public_key = [_]u8{3} ** 33,
                .node_id = [_]u8{30} ** 32,
                .is_trusted = true,
            },
            .{
                .public_key = [_]u8{4} ** 33,
                .node_id = [_]u8{40} ** 32,
                .is_trusted = true,
            },
            .{
                .public_key = [_]u8{5} ** 33,
                .node_id = [_]u8{50} ** 32,
                .is_trusted = true,
            },
        };

        for (default_validators) |v| {
            try self.unl.append(v);
        }
    }

    /// Add a validator
    pub fn addValidator(self: *ValidatorManager, validator: Validator) !void {
        try self.validators.append(validator);
    }

    /// Get trusted validators (UNL)
    pub fn getTrustedValidators(self: *const ValidatorManager) []const consensus.ValidatorInfo {
        return self.unl.items;
    }

    /// Verify a validator's manifest
    pub fn verifyManifest(self: *ValidatorManager, manifest: []const u8) !bool {
        // TODO: Implement manifest verification
        _ = self;
        _ = manifest;
        return true;
    }
};

/// A validator node
pub const Validator = struct {
    public_key: [33]u8,
    master_key: [33]u8,
    signing_key: [33]u8,
    sequence: u32,
    manifest_data: []u8,
    is_trusted: bool,

    /// Verify validator signature
    pub fn verifySignature(self: *const Validator, data: []const u8, signature: []const u8) !bool {
        return try crypto.KeyPair.verify(&self.signing_key, data, signature, .ed25519);
    }
};

test "validator manager" {
    const allocator = std.testing.allocator;
    var manager = try ValidatorManager.init(allocator);
    defer manager.deinit();

    try manager.loadUNL("default");

    const trusted = manager.getTrustedValidators();
    try std.testing.expectEqual(@as(usize, 5), trusted.len);
}
