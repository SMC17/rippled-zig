const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_secp256k1 = b.option(bool, "secp256k1", "Link against libsecp256k1 for ECDSA verification") orelse true;
    const experimental = b.option(bool, "experimental", "Include experimental node subsystems (consensus, network, p2p)") orelse false;
    const gate_e_fuzz_cases = b.option(u32, "gate_e_fuzz_cases", "Gate E fuzz case budget") orelse 25000;
    const gate_e_profile = b.option([]const u8, "gate_e_profile", "Gate E profile label") orelse "pr";

    const build_options = b.addOptions();
    build_options.addOption(bool, "has_secp256k1", use_secp256k1);
    build_options.addOption(bool, "experimental", experimental);
    build_options.addOption(u32, "gate_e_fuzz_cases", gate_e_fuzz_cases);
    build_options.addOption([]const u8, "gate_e_profile", gate_e_profile);

    // ── Main executable (toolkit CLI by default, full node with -Dexperimental) ──
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_module.addOptions("build_options", build_options);

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
    const run_step = b.step("run", "Run rippled-zig (toolkit CLI by default)");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──
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

    // ── Gate B: deterministic serialization/hash checks ──
    const gate_b_module = b.createModule(.{
        .root_source_file = b.path("src/determinism_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_b_module.addOptions("build_options", build_options);
    const gate_b_exe = b.addExecutable(.{
        .name = "gate-b-check",
        .root_module = gate_b_module,
    });
    gate_b_exe.linkLibC();
    if (use_secp256k1) {
        gate_b_exe.linkSystemLibrary("secp256k1");
    }
    const run_gate_b_tests = b.addRunArtifact(gate_b_exe);
    const gate_b_step = b.step("gate-b", "Run Gate B deterministic checks");
    gate_b_step.dependOn(&run_gate_b_tests.step);

    // ── Gate C: parity and contract checks ──
    const gate_c_module = b.createModule(.{
        .root_source_file = b.path("src/parity_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_c_module.addOptions("build_options", build_options);
    const gate_c_exe = b.addExecutable(.{
        .name = "gate-c-check",
        .root_module = gate_c_module,
    });
    gate_c_exe.linkLibC();
    if (use_secp256k1) {
        gate_c_exe.linkSystemLibrary("secp256k1");
    }
    const run_gate_c_tests = b.addRunArtifact(gate_c_exe);
    const gate_c_step = b.step("gate-c", "Run Gate C parity checks");
    gate_c_step.dependOn(&run_gate_c_tests.step);

    // ── Gate E: security checks ──
    const gate_e_module = b.createModule(.{
        .root_source_file = b.path("src/security_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_e_module.addOptions("build_options", build_options);
    const gate_e_exe = b.addExecutable(.{
        .name = "gate-e-check",
        .root_module = gate_e_module,
    });
    gate_e_exe.linkLibC();
    if (use_secp256k1) {
        gate_e_exe.linkSystemLibrary("secp256k1");
    }
    const run_gate_e_tests = b.addRunArtifact(gate_e_exe);
    const gate_e_step = b.step("gate-e", "Run Gate E security checks");
    gate_e_step.dependOn(&run_gate_e_tests.step);

    // ── WASM: Protocol kernel ──
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/protocol_kernel.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const kernel_exe = b.addExecutable(.{
        .name = "protocol_kernel",
        .root_module = kernel_module,
    });
    kernel_exe.entry = .disabled;
    const kernel_install = b.addInstallArtifact(kernel_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    const kernel_step = b.step("wasm-kernel", "Build protocol kernel as WASM");
    kernel_step.dependOn(&kernel_install.step);

    // ── WASM: Hooks template ──
    const hook_module = b.createModule(.{
        .root_source_file = b.path("examples/hook_template.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const hook_exe = b.addExecutable(.{
        .name = "hook_template",
        .root_module = hook_module,
    });
    hook_exe.entry = .disabled;
    hook_exe.rdynamic = true;
    const hook_install = b.addInstallArtifact(hook_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    const hook_step = b.step("wasm-hook", "Build Hooks template as WASM");
    hook_step.dependOn(&hook_install.step);

    const wasm_step = b.step("wasm", "Build all WASM targets (kernel + hook)");
    wasm_step.dependOn(&kernel_install.step);
    wasm_step.dependOn(&hook_install.step);

    // ── Cross-compilation release builds ──
    const release_step = b.step("release", "Build release binaries for all platforms");

    const CrossTarget = struct {
        name: []const u8,
        cpu_arch: std.Target.Cpu.Arch,
        os_tag: std.Target.Os.Tag,
        abi: ?std.Target.Abi = null,
        is_wasm: bool = false,
    };

    const cross_targets = [_]CrossTarget{
        .{ .name = "x86_64-linux", .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .name = "aarch64-linux", .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .name = "x86_64-macos", .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .name = "aarch64-macos", .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .name = "x86_64-windows", .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .name = "wasm32-freestanding", .cpu_arch = .wasm32, .os_tag = .freestanding, .is_wasm = true },
    };

    for (cross_targets) |ct| {
        var query: std.Target.Query = .{
            .cpu_arch = ct.cpu_arch,
            .os_tag = ct.os_tag,
        };
        if (ct.abi) |abi| {
            query.abi = abi;
        }
        const resolved = b.resolveTargetQuery(query);

        if (ct.is_wasm) {
            // WASM: build protocol library only (no CLI, no libc)
            const wasm_lib_module = b.createModule(.{
                .root_source_file = b.path("src/wasm_lib.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
            });
            const wasm_lib_exe = b.addExecutable(.{
                .name = "rippled-zig-lib",
                .root_module = wasm_lib_module,
            });
            wasm_lib_exe.entry = .disabled;
            wasm_lib_exe.rdynamic = true;
            const wasm_lib_install = b.addInstallArtifact(wasm_lib_exe, .{
                .dest_dir = .{ .override = .{ .custom = "release/wasm32-freestanding" } },
            });
            release_step.dependOn(&wasm_lib_install.step);
        } else {
            // Native CLI binary
            const rel_build_options = b.addOptions();
            rel_build_options.addOption(bool, "has_secp256k1", false);
            rel_build_options.addOption(bool, "experimental", false);
            rel_build_options.addOption(u32, "gate_e_fuzz_cases", 25000);
            rel_build_options.addOption([]const u8, "gate_e_profile", "release");

            const rel_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
            });
            rel_module.addOptions("build_options", rel_build_options);

            const rel_exe = b.addExecutable(.{
                .name = "rippled-zig",
                .root_module = rel_module,
            });
            // Link libc for native targets (use default libc for cross targets)
            rel_exe.linkLibC();
            const rel_install = b.addInstallArtifact(rel_exe, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{ct.name}) } },
            });
            release_step.dependOn(&rel_install.step);
        }
    }

    // ── Release checksums ──
    const checksums_step = b.step("release-checksums", "Build all release targets and generate SHA256SUMS");
    checksums_step.dependOn(release_step);
    const checksums_run = b.addSystemCommand(&.{
        "sh", "-c",
        "cd zig-out/release && find . -type f \\( -name 'rippled-zig' -o -name 'rippled-zig.exe' -o -name 'rippled-zig-lib.wasm' \\) -exec shasum -a 256 {} \\; > SHA256SUMS && cat SHA256SUMS",
    });
    checksums_run.step.dependOn(release_step);
    checksums_step.dependOn(&checksums_run.step);

    // ── Experimental-only build steps ──
    if (experimental) {
        // Consensus experiment harness
        const consensus_exp_module = b.createModule(.{
            .root_source_file = b.path("tools/consensus_experiment.zig"),
            .target = target,
            .optimize = optimize,
        });
        consensus_exp_module.addImport("consensus", b.createModule(.{
            .root_source_file = b.path("src/consensus.zig"),
            .target = target,
            .optimize = optimize,
        }));
        const consensus_exp_exe = b.addExecutable(.{
            .name = "consensus-experiment",
            .root_module = consensus_exp_module,
        });
        consensus_exp_exe.linkLibC();
        if (use_secp256k1) {
            consensus_exp_exe.linkSystemLibrary("secp256k1");
        }
        const run_consensus_exp = b.addRunArtifact(consensus_exp_exe);
        if (b.args) |args| {
            run_consensus_exp.addArgs(args);
        }
        const consensus_exp_step = b.step("consensus-experiment", "Run parameterized consensus experiment harness");
        consensus_exp_step.dependOn(&run_consensus_exp.step);
    }

    // Control-plane policy snapshot (always available — it's a conformance tool)
    const policy_snapshot_module = b.createModule(.{
        .root_source_file = b.path("tools/control_plane_policy_snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    policy_snapshot_module.addOptions("build_options", build_options);
    policy_snapshot_module.addImport("rpc_methods", b.createModule(.{
        .root_source_file = b.path("src/rpc_methods.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const policy_snapshot_exe = b.addExecutable(.{
        .name = "control-plane-policy-snapshot",
        .root_module = policy_snapshot_module,
    });
    policy_snapshot_exe.linkLibC();
    if (use_secp256k1) {
        policy_snapshot_exe.linkSystemLibrary("secp256k1");
    }
    const run_policy_snapshot = b.addRunArtifact(policy_snapshot_exe);
    if (b.args) |args| {
        run_policy_snapshot.addArgs(args);
    }
    const policy_snapshot_step = b.step("control-plane-policy-snapshot", "Emit deterministic control-plane policy snapshot JSON");
    policy_snapshot_step.dependOn(&run_policy_snapshot.step);
}
