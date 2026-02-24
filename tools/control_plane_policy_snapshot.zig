const std = @import("std");
const rpc_methods = @import("rpc_methods");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const snapshot = try rpc_methods.RpcMethods.controlPlanePolicySnapshotJson(allocator);
    defer allocator.free(snapshot);
    if (args.len >= 2) {
        try std.fs.cwd().writeFile(.{ .sub_path = args[1], .data = snapshot });
    } else {
        std.debug.print("{s}\n", .{snapshot});
    }
}
