//! `zf gate` / `zf release-check` — productized quality & release gates.
const std = @import("std");
const zf_shared = @import("zf_shared.zig");
const zf_cfg = @import("zf_cfg");

/// Modes mirror `scripts/quality_gate.sh`.
pub const Mode = enum { quick, full, release };

pub fn handleGate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const json_mode = zf_shared.hasFlag(args, "--json");
    const strict = zf_shared.hasFlag(args, "--strict");
    var mode: Mode = .full;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--quick") or std.mem.eql(u8, a, "quick")) mode = .quick;
        if (std.mem.eql(u8, a, "--release") or std.mem.eql(u8, a, "release")) mode = .release;
        if (std.mem.eql(u8, a, "--full") or std.mem.eql(u8, a, "full")) mode = .full;
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printHelp(args[0]);
            return;
        }
    }
    try runGate(allocator, mode, json_mode, strict);
}

pub fn handleReleaseCheck(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const json_mode = zf_shared.hasFlag(args, "--json");
    // Default --strict for release-check; opt out with --no-strict.
    const strict = !zf_shared.hasFlag(args, "--no-strict");
    if (zf_shared.hasFlag(args, "-h") or zf_shared.hasFlag(args, "--help")) {
        printReleaseHelp(args[0]);
        return;
    }
    try runGate(allocator, .release, json_mode, strict);
}

fn printHelp(exe: []const u8) void {
    std.debug.print(
        \\Usage: {s} gate [--quick|--full|--release] [--strict] [--json]
        \\  Run scripts/quality_gate.sh (fmt, version, test, test-zf, …).
        \\  --quick    fmt + version + build + test + test-zf
        \\  --full     + ReleaseSafe + zf check --prod + routes --check (default)
        \\  --release  + CHANGELOG ## [semver] + tag collision check
        \\  --strict   release: dirty tree fails (default warn)
        \\
    , .{exe});
}

fn printReleaseHelp(exe: []const u8) void {
    std.debug.print(
        \\Usage: {s} release-check [--json] [--no-strict]
        \\  Alias for `{s} gate --release --strict`. Pass before tagging vX.Y.Z.
        \\  --no-strict  allow dirty working tree (warn only)
        \\  See doc/release_and_quality_gates.md
        \\
    , .{ exe, exe });
}

fn runGate(allocator: std.mem.Allocator, mode: Mode, json_mode: bool, strict: bool) !void {
    const mode_str: []const u8 = switch (mode) {
        .quick => "quick",
        .full => "full",
        .release => "release",
    };

    const script = "scripts/quality_gate.sh";
    std.Io.Dir.cwd().access(zf_shared.io, script, .{}) catch {
        std.debug.print("error: {s} not found (run from zfinal repo root)\n", .{script});
        if (json_mode) {
            std.debug.print("{{\"ok\":false,\"error\":\"missing_script\",\"version\":\"{s}\"}}\n", .{zf_cfg.version});
        }
        std.process.exit(1);
    };

    var argv_buf: [4][]const u8 = undefined;
    var argv_len: usize = 2;
    argv_buf[0] = "bash";
    argv_buf[1] = script;
    argv_buf[2] = mode_str;
    argv_len = 3;
    if (strict) {
        argv_buf[3] = "--strict";
        argv_len = 4;
    }

    var child = try std.process.spawn(zf_shared.io, .{
        .argv = argv_buf[0..argv_len],
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    _ = allocator;
    const term = try child.wait(zf_shared.io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    if (json_mode) {
        const strict_json: []const u8 = if (strict) "true" else "false";
        if (code == 0) {
            std.debug.print("{{\"ok\":true,\"mode\":\"{s}\",\"strict\":{s},\"version\":\"{s}\"}}\n", .{ mode_str, strict_json, zf_cfg.version });
        } else {
            std.debug.print("{{\"ok\":false,\"mode\":\"{s}\",\"strict\":{s},\"version\":\"{s}\",\"exit\":{d}}}\n", .{ mode_str, strict_json, zf_cfg.version, code });
        }
    }
    if (code != 0) std.process.exit(code);
}
