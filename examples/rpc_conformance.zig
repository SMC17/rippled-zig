const std = @import("std");

/// Example: Validate RPC responses against schema contracts
///
/// This demonstrates the toolkit's conformance checking approach:
/// given a JSON blob (from a real or mocked rippled RPC response),
/// validate that it contains the required fields with correct types.
///
/// In production use, you would:
///   1. Capture responses from a live rippled node or testnet
///   2. Run them through these schema validators
///   3. Assert that your implementation produces compatible output
///
/// This example works without network access -- it validates against
/// hardcoded fixture data that matches known rippled responses.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("rippled-zig Toolkit: RPC Conformance Checks\n", .{});
    std.debug.print("=============================================\n\n", .{});

    var pass_count: u32 = 0;
    var fail_count: u32 = 0;

    // ---------------------------------------------------------------
    // 1. Validate server_info response schema
    // ---------------------------------------------------------------
    //
    // A conforming server_info response must contain:
    //   result.info.build_version  (string)
    //   result.info.server_state   (string, one of known states)
    //   result.info.peers          (integer >= 0)
    //   result.info.validated_ledger.hash  (64-char hex string)
    //   result.info.validated_ledger.seq   (integer > 0)

    std.debug.print("1. server_info response schema\n", .{});
    std.debug.print("   --------------------------\n", .{});

    const server_info_json =
        \\{
        \\  "result": {
        \\    "info": {
        \\      "build_version": "2.3.0",
        \\      "server_state": "full",
        \\      "peers": 21,
        \\      "validated_ledger": {
        \\        "hash": "4BC50C9B0D8515D3EAAE1E74B29A95804346C491EE1A95BF25E4AAB854A6A652",
        \\        "seq": 90123456
        \\      }
        \\    },
        \\    "status": "success"
        \\  }
        \\}
    ;

    const server_info_parsed = try std.json.parseFromSlice(std.json.Value, allocator, server_info_json, .{});
    defer server_info_parsed.deinit();
    const si = server_info_parsed.value;

    // Check result.info.build_version exists and is a string
    if (navigate(si, &.{ "result", "info", "build_version" })) |val| {
        if (val == .string) {
            std.debug.print("   [PASS] build_version is string: \"{s}\"\n", .{val.string});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] build_version is not a string\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] build_version missing\n", .{});
        fail_count += 1;
    }

    // Check server_state is a recognized value
    const valid_states = [_][]const u8{ "disconnected", "connected", "syncing", "tracking", "full", "validating", "proposing" };
    if (navigate(si, &.{ "result", "info", "server_state" })) |val| {
        if (val == .string) {
            var recognized = false;
            for (valid_states) |state| {
                if (std.mem.eql(u8, val.string, state)) {
                    recognized = true;
                    break;
                }
            }
            if (recognized) {
                std.debug.print("   [PASS] server_state is recognized: \"{s}\"\n", .{val.string});
                pass_count += 1;
            } else {
                std.debug.print("   [FAIL] server_state unrecognized: \"{s}\"\n", .{val.string});
                fail_count += 1;
            }
        } else {
            std.debug.print("   [FAIL] server_state is not a string\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] server_state missing\n", .{});
        fail_count += 1;
    }

    // Check peers is a non-negative integer
    if (navigate(si, &.{ "result", "info", "peers" })) |val| {
        if (val == .integer and val.integer >= 0) {
            std.debug.print("   [PASS] peers is non-negative integer: {d}\n", .{val.integer});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] peers is not a non-negative integer\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] peers missing\n", .{});
        fail_count += 1;
    }

    // Check validated_ledger.hash is a 64-char hex string
    if (navigate(si, &.{ "result", "info", "validated_ledger", "hash" })) |val| {
        if (val == .string and val.string.len == 64 and isHex(val.string)) {
            std.debug.print("   [PASS] ledger hash is 64-char hex: {s}...{s}\n", .{ val.string[0..8], val.string[56..64] });
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] ledger hash is not a 64-char hex string\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] validated_ledger.hash missing\n", .{});
        fail_count += 1;
    }

    // Check validated_ledger.seq is a positive integer
    if (navigate(si, &.{ "result", "info", "validated_ledger", "seq" })) |val| {
        if (val == .integer and val.integer > 0) {
            std.debug.print("   [PASS] ledger seq is positive: {d}\n", .{val.integer});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] ledger seq is not a positive integer\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] validated_ledger.seq missing\n", .{});
        fail_count += 1;
    }

    // ---------------------------------------------------------------
    // 2. Validate fee response schema
    // ---------------------------------------------------------------
    //
    // A conforming fee response must contain:
    //   result.drops.base_fee        (string of integer drops)
    //   result.drops.median_fee      (string of integer drops)
    //   result.drops.minimum_fee     (string of integer drops)
    //   result.ledger_current_index  (integer > 0)
    //   result.status                ("success")

    std.debug.print("\n2. fee response schema\n", .{});
    std.debug.print("   -------------------\n", .{});

    const fee_json =
        \\{
        \\  "result": {
        \\    "drops": {
        \\      "base_fee": "10",
        \\      "median_fee": "5000",
        \\      "minimum_fee": "10",
        \\      "open_ledger_fee": "10"
        \\    },
        \\    "ledger_current_index": 90123457,
        \\    "status": "success"
        \\  }
        \\}
    ;

    const fee_parsed = try std.json.parseFromSlice(std.json.Value, allocator, fee_json, .{});
    defer fee_parsed.deinit();
    const fee = fee_parsed.value;

    // Check each fee field is a string that parses as a non-negative integer
    const fee_fields = [_][]const u8{ "base_fee", "median_fee", "minimum_fee" };
    for (fee_fields) |field_name| {
        if (navigate(fee, &.{ "result", "drops", field_name })) |val| {
            if (val == .string) {
                const parsed = std.fmt.parseInt(u64, val.string, 10) catch null;
                if (parsed) |drops| {
                    std.debug.print("   [PASS] {s} is numeric string: \"{s}\" ({d} drops)\n", .{ field_name, val.string, drops });
                    pass_count += 1;
                } else {
                    std.debug.print("   [FAIL] {s} is not a numeric string: \"{s}\"\n", .{ field_name, val.string });
                    fail_count += 1;
                }
            } else {
                std.debug.print("   [FAIL] {s} is not a string\n", .{field_name});
                fail_count += 1;
            }
        } else {
            std.debug.print("   [FAIL] {s} missing\n", .{field_name});
            fail_count += 1;
        }
    }

    // Check ledger_current_index
    if (navigate(fee, &.{ "result", "ledger_current_index" })) |val| {
        if (val == .integer and val.integer > 0) {
            std.debug.print("   [PASS] ledger_current_index: {d}\n", .{val.integer});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] ledger_current_index is not a positive integer\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] ledger_current_index missing\n", .{});
        fail_count += 1;
    }

    // Check status == "success"
    if (navigate(fee, &.{ "result", "status" })) |val| {
        if (val == .string and std.mem.eql(u8, val.string, "success")) {
            std.debug.print("   [PASS] status: \"success\"\n", .{});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] status is not \"success\"\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] status missing\n", .{});
        fail_count += 1;
    }

    // ---------------------------------------------------------------
    // 3. Validate account_info error response schema
    // ---------------------------------------------------------------
    //
    // When an account does not exist, rippled returns:
    //   result.status       = "error"
    //   result.error        = "actNotFound"
    //   result.error_code   = 19
    //   result.validated    = true (if validated ledger was queried)

    std.debug.print("\n3. account_info error response schema\n", .{});
    std.debug.print("   -----------------------------------\n", .{});

    const account_error_json =
        \\{
        \\  "result": {
        \\    "account": "rNotExist111111111111111113",
        \\    "error": "actNotFound",
        \\    "error_code": 19,
        \\    "error_message": "Account not found.",
        \\    "ledger_index": 90123456,
        \\    "request": {
        \\      "account": "rNotExist111111111111111113",
        \\      "command": "account_info",
        \\      "ledger_index": "validated"
        \\    },
        \\    "status": "error",
        \\    "validated": true
        \\  }
        \\}
    ;

    const acct_parsed = try std.json.parseFromSlice(std.json.Value, allocator, account_error_json, .{});
    defer acct_parsed.deinit();
    const acct = acct_parsed.value;

    // Check status == "error"
    if (navigate(acct, &.{ "result", "status" })) |val| {
        if (val == .string and std.mem.eql(u8, val.string, "error")) {
            std.debug.print("   [PASS] status: \"error\"\n", .{});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] status is not \"error\"\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] status missing\n", .{});
        fail_count += 1;
    }

    // Check error == "actNotFound"
    if (navigate(acct, &.{ "result", "error" })) |val| {
        if (val == .string and std.mem.eql(u8, val.string, "actNotFound")) {
            std.debug.print("   [PASS] error: \"actNotFound\"\n", .{});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] error is not \"actNotFound\"\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] error field missing\n", .{});
        fail_count += 1;
    }

    // Check error_code == 19
    if (navigate(acct, &.{ "result", "error_code" })) |val| {
        if (val == .integer and val.integer == 19) {
            std.debug.print("   [PASS] error_code: 19\n", .{});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] error_code is not 19\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] error_code missing\n", .{});
        fail_count += 1;
    }

    // Check validated == true
    if (navigate(acct, &.{ "result", "validated" })) |val| {
        if (val == .bool and val.bool) {
            std.debug.print("   [PASS] validated: true\n", .{});
            pass_count += 1;
        } else {
            std.debug.print("   [FAIL] validated is not true\n", .{});
            fail_count += 1;
        }
    } else {
        std.debug.print("   [FAIL] validated missing\n", .{});
        fail_count += 1;
    }

    // ---------------------------------------------------------------
    // Summary
    // ---------------------------------------------------------------

    const total = pass_count + fail_count;
    std.debug.print("\n====================================\n", .{});
    std.debug.print("Conformance results: {d}/{d} checks passed\n", .{ pass_count, total });

    if (fail_count == 0) {
        std.debug.print("All schema contracts satisfied.\n", .{});
    } else {
        std.debug.print("{d} check(s) failed.\n", .{fail_count});
    }

    std.debug.print("\nNext steps:\n", .{});
    std.debug.print("  - Point these checks at live testnet responses\n", .{});
    std.debug.print("  - Add tx_info and ledger response schemas\n", .{});
    std.debug.print("  - Integrate into CI as Gate C conformance checks\n", .{});
}

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

/// Navigate a nested JSON value by key path. Returns null if any key
/// is missing or the intermediate value is not an object.
fn navigate(root: std.json.Value, path: []const []const u8) ?std.json.Value {
    var current = root;
    for (path) |key| {
        switch (current) {
            .object => |obj| {
                if (obj.get(key)) |next| {
                    current = next;
                } else {
                    return null;
                }
            },
            else => return null,
        }
    }
    return current;
}

/// Check if a string contains only hexadecimal characters (0-9, a-f, A-F).
fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}
