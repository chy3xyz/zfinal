//! `zf gate` / `zf release-check` — productized quality & release gates.
const std = @import("std");
const zf_shared = @import("zf_shared.zig");
const zf_cfg = @import("zf_cfg");

/// Modes mirror `scripts/quality_gate.sh`.
pub const Mode = enum { quick, full, release };

pub fn handleGate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const json_mode = zf_shared.hasFlag(args, "--json");
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
    try runGate(allocator, mode, json_mode);
}

pub fn handleReleaseCheck(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const json_mode = zf_shared.hasFlag(args, "--json");
    if (zf_shared.hasFlag(args, "-h") or zf_shared.hasFlag(args, "--help")) {
        printReleaseHelp(args[0]);
        return;
    }
    try runGate(allocator, .release, json_mode);
}

fn printHelp(exe: []const u8) void {
    std.debug.print(
        \\Usage: {s} gate [--quick|--full|--release] [--json]
        \\  Run scripts/quality_gate.sh (fmt, version, test, test-zf, …).
        \\  --quick    fmt + version + build + test + test-zf
        \\  --full     + ReleaseSafe + zf check --prod + routes --check (default)
        \\  --release  + CHANGELOG / dirty-tree warn (pre-tag)
        \\
    , .{exe});
}

fn printReleaseHelp(exe: []const u8) void {
    std.debug.print(
        \\Usage: {s} release-check [--json]
        \\  Alias for `{s} gate --release`. Pass before tagging vX.Y.Z.
        \\  See doc/release_and_quality_gates.md
        \\
    , .{ exe, exe });
}

fn runGate(allocator: std.mem.Allocator, mode: Mode, json_mode: bool) !void {
    _ = allocator;
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

    var child = try std.process.spawn(zf_shared.io, .{
        .argv = &.{ "bash", script, mode_str },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(zf_shared.io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    if (json_mode) {
        if (code == 0) {
            std.debug.print("{{\"ok\":true,\"mode\":\"{s}\",\"version\":\"{s}\"}}\n", .{ mode_str, zf_cfg.version });
        } else {
            std.debug.print("{{\"ok\":false,\"mode\":\"{s}\",\"version\":\"{s}\",\"exit\":{d}}}\n", .{ mode_str, zf_cfg.version, code });
        }
    }
    if (code != 0) std.process.exit(code);
}
