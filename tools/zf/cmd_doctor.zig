//! `zf doctor` — diagnose PATH/version/project wiring.
const std = @import("std");
const zf_cfg = @import("zf_cfg");
const zf_shared = @import("zf_shared.zig");
const cmd_catalog = @import("cmd_catalog.zig");

pub fn handleDoctor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const json_mode = zf_shared.hasFlag(args, "--json");
    if (zf_shared.hasFlag(args, "-h") or zf_shared.hasFlag(args, "--help")) {
        printHelp(args[0]);
        return;
    }

    var issues: u32 = 0;
    var hints = std.ArrayList([]const u8).empty;
    defer {
        for (hints.items) |h| allocator.free(h);
        hints.deinit(allocator);
    }

    const argv0 = if (args.len > 0) args[0] else "zf";
    const in_zig_out = std.mem.indexOf(u8, argv0, "zig-out") != null;

    const has_zon = fileExists("build.zig.zon");
    const has_claude = fileExists("CLAUDE.md");
    const has_modules = dirExists("src/modules");
    const has_actions = try anyActionsZig();
    const has_life = fileExists(".life/dna.json");

    var zon_semver: ?[]const u8 = null;
    defer if (zon_semver) |s| allocator.free(s);
    if (has_zon) {
        if (readZonVersion(allocator)) |v| {
            zon_semver = v;
        } else |_| {}
    }

    const version_mismatch = if (zon_semver) |zv|
        !std.mem.eql(u8, zv, zf_cfg.semver)
    else
        false;

    if (!in_zig_out) {
        issues += 1;
        try hints.append(allocator, try allocator.dupe(u8, "argv0 is not under zig-out/bin — rebuild: zig build install-zf && use ./zig-out/bin/zf"));
    }
    if (version_mismatch) {
        issues += 1;
        try hints.append(allocator, try std.fmt.allocPrint(allocator, "CLI semver {s} != build.zig.zon {s}", .{ zf_cfg.semver, zon_semver.? }));
    }
    if (has_modules and !has_actions) {
        issues += 1;
        try hints.append(allocator, try allocator.dupe(u8, "src/modules exists but no actions.zig — run zf crud:sql|zent then zf routes"));
    }
    if (!has_claude and has_zon) {
        try hints.append(allocator, try allocator.dupe(u8, "No CLAUDE.md — AI agents lack project rules (zf new generates one)"));
    }

    var missing_cmds: u32 = 0;
    for (cmd_catalog.required_help_names) |name| {
        if (cmd_catalog.parseCommand(name) == null) missing_cmds += 1;
    }
    if (missing_cmds > 0) {
        issues += 1;
        try hints.append(allocator, try allocator.dupe(u8, "internal: required commands missing from catalog"));
    }

    if (json_mode) {
        std.debug.print("{{\"ok\":{s},\"version\":\"{s}\",\"semver\":\"{s}\",\"argv0\":\"", .{
            if (issues == 0) "true" else "false",
            zf_cfg.version,
            zf_cfg.semver,
        });
        zf_shared.printJsonStringEscaped(argv0);
        std.debug.print("\",\"in_zig_out\":{s},\"has_build_zon\":{s},\"has_modules\":{s},\"has_actions\":{s},\"has_claude\":{s},\"has_life\":{s},\"issues\":{d},\"hints\":[", .{
            if (in_zig_out) "true" else "false",
            if (has_zon) "true" else "false",
            if (has_modules) "true" else "false",
            if (has_actions) "true" else "false",
            if (has_claude) "true" else "false",
            if (has_life) "true" else "false",
            issues,
        });
        for (hints.items, 0..) |h, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("\"", .{});
            zf_shared.printJsonStringEscaped(h);
            std.debug.print("\"", .{});
        }
        std.debug.print("]}}\n", .{});
    } else {
        std.debug.print("\nzf doctor\n", .{});
        std.debug.print("=========\n", .{});
        std.debug.print("  version:     {s} (semver {s})\n", .{ zf_cfg.version, zf_cfg.semver });
        std.debug.print("  argv0:       {s}\n", .{argv0});
        std.debug.print("  zig-out bin: {s}\n", .{if (in_zig_out) "yes" else "NO — prefer ./zig-out/bin/zf"});
        if (zon_semver) |zv| {
            std.debug.print("  build.zon:   {s}{s}\n", .{ zv, if (version_mismatch) " (MISMATCH)" else "" });
        } else {
            std.debug.print("  build.zon:   (not in zfinal app/repo root)\n", .{});
        }
        std.debug.print("  CLAUDE.md:   {s}\n", .{if (has_claude) "yes" else "no"});
        std.debug.print("  modules/:    {s}\n", .{if (has_modules) "yes" else "no"});
        std.debug.print("  actions.zig: {s}\n", .{if (has_actions) "yes" else "no"});
        std.debug.print("  .life/:      {s}\n", .{if (has_life) "yes" else "no"});
        if (hints.items.len > 0) {
            std.debug.print("\nHints:\n", .{});
            for (hints.items) |h| std.debug.print("  - {s}\n", .{h});
        } else {
            std.debug.print("\nOK — no issues detected.\n", .{});
        }
        std.debug.print("\nNext: zf check [--prod --root .] [--practice] · zf routes --json · zf gate --quick\n\n", .{});
    }

    if (issues > 0) std.process.exit(zf_shared.Exit.warn);
}

fn printHelp(exe: []const u8) void {
    std.debug.print(
        \\Usage: {s} doctor [--json]
        \\  Diagnose which zf binary is running, version sync, and project wiring.
        \\
    , .{exe});
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(zf_shared.io, path, .{}) catch return false;
    return true;
}

fn dirExists(path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(zf_shared.io, path, .{}) catch return false;
    d.close(zf_shared.io);
    return true;
}

fn readZonVersion(allocator: std.mem.Allocator) ![]const u8 {
    const data = try zf_shared.readFileAlloc(allocator, "build.zig.zon");
    defer allocator.free(data);
    const key = ".version = \"";
    const start = std.mem.indexOf(u8, data, key) orelse return error.NotFound;
    const from = start + key.len;
    const end = std.mem.indexOfScalar(u8, data[from..], '"') orelse return error.NotFound;
    return try allocator.dupe(u8, data[from .. from + end]);
}

fn anyActionsZig() !bool {
    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, "src/modules", .{ .iterate = true }) catch return false;
    defer dir.close(zf_shared.io);
    return walkForActions(&dir);
}

fn walkForActions(dir: *std.Io.Dir) bool {
    var it = dir.iterate();
    while (it.next(zf_shared.io) catch null) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.name, "actions.zig")) return true;
        if (entry.kind == .directory) {
            var sub = dir.openDir(zf_shared.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(zf_shared.io);
            if (walkForActions(&sub)) return true;
        }
    }
    return false;
}
