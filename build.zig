const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_secp256k1 = b.option(bool, "secp256k1", "Link against libsecp256k1 for ECDSA verification") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "has_secp256k1", use_secp256k1);

    // Create main module
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_module.addOptions("build_options", build_options);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "rippled-zig",
        .root_module = main_module,
    });
    exe.linkLibC();
    if (use_secp256k1) {
        exe.linkSystemLibrary("secp256k1");
    }

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the XRP Ledger daemon");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", build_options);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    unit_tests.linkLibC();
    if (use_secp256k1) {
        unit_tests.linkSystemLibrary("secp256k1");
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
