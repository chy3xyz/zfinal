//! Shared CLI helpers for the `zf` tool (IO, FS, flags, safe writes).
const std = @import("std");

pub var io: std.Io = undefined;

pub const framework_skill_names = [_][]const u8{
    "zfinal-onboarding.md",
    "zfinal-ai-playbook.md",
    "zfinal-framework.md",
    "zfinal-health.md",
    "zfinal-evolution.md",
    "zfinal-debug.md",
    "zfinal-evolve.md",
};

pub fn writeFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const stat = try f.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    const chunks = [_][]u8{buf};
    _ = try f.readStreaming(io, &chunks);
    return buf;
}

pub fn capitalizeOwned(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    if (str.len == 0) return try allocator.dupe(u8, str);
    var result = try allocator.alloc(u8, str.len);
    result[0] = std.ascii.toUpper(str[0]);
    @memcpy(result[1..], str[1..]);
    return result;
}

pub fn hasFlag(args: [][]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

pub fn ensureDir(allocator: std.mem.Allocator, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Failed to create directory {s}: {}\n", .{ path, err });
            return err;
        }
    };
    _ = allocator;
}

pub fn pascalCaseConvert(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    var cap = true;
    for (name) |c| {
        if (c == '_' or c == '-') {
            cap = true;
            continue;
        }
        try result.append(allocator, if (cap) std.ascii.toUpper(c) else c);
        cap = false;
    }
    if (result.items.len > 0) result.items[0] = std.ascii.toUpper(result.items[0]);
    return result.toOwnedSlice(allocator);
}

const zone_merge = @import("zone_merge.zig");

pub fn flagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

/// Write file safely:
/// 1. Missing or `--force` → write `data` to `path`.
/// 2. Existing file with matching `ai-edit-zone` names → merge zones into `path`.
/// 3. Else → write `data` to `path.gen.new` (no overwrite).
pub fn safeWrite(allocator: std.mem.Allocator, path: []const u8, data: []const u8, force: bool) !void {
    const exists = std.Io.Dir.cwd().access(io, path, .{}) != error.FileNotFound;
    if (!exists or force) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        const tag: []const u8 = if (force and exists) "Overwritten" else "Generated";
        std.debug.print("✅ {s}: {s}\n", .{ tag, path });
        return;
    }

    const existing = readFileAlloc(allocator, path) catch {
        const new_path = try std.fmt.allocPrint(allocator, "{s}.gen.new", .{path});
        defer allocator.free(new_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = new_path, .data = data });
        std.debug.print("⚠️  EXISTS: {s} — generated to {s} (could not read original)\n", .{ path, new_path });
        return;
    };
    defer allocator.free(existing);

    if (try zone_merge.mergeAiEditZones(allocator, existing, data)) |merged| {
        defer allocator.free(merged);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = merged });
        std.debug.print("✅ Merged ai-edit-zones: {s}\n", .{path});
        return;
    }

    const new_path = try std.fmt.allocPrint(allocator, "{s}.gen.new", .{path});
    defer allocator.free(new_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = new_path, .data = data });
    std.debug.print("⚠️  EXISTS: {s} — no matching ai-edit-zones; wrote {s}\n", .{ path, new_path });
    std.debug.print("   Review with: diff {s} {s}  then merge, or use --force\n", .{ path, new_path });
}

/// Append a JSON-escaped string (no surrounding quotes).
pub fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            else => if (c < 0x20) {
                var esc: [8]u8 = undefined;
                const len = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c});
                try buf.appendSlice(allocator, len);
            } else {
                const ch: [1]u8 = .{c};
                try buf.appendSlice(allocator, &ch);
            },
        }
    }
}

const templates = @import("templates.zig");

pub fn writeAiConfigs(allocator: std.mem.Allocator, cwd: std.Io.Dir) !void {
    // .claude/skills/ — copy framework skills from sibling .claude/skills/
    try cwd.createDirPath(io, ".claude/skills");
    var claude_dir = try cwd.openDir(io, ".claude/skills", .{});
    defer claude_dir.close(io);
    // Summary skill (always present)
    try writeFile(claude_dir, "zfinal-app.md", templates.claude_skill);
    // Copy full framework skill set from sibling repo
    copyFrameworkSkills(allocator, claude_dir);

    // .opencode/
    try cwd.createDirPath(io, ".opencode");
    var opencode_dir = try cwd.openDir(io, ".opencode", .{});
    defer opencode_dir.close(io);
    try writeFile(opencode_dir, "instructions.md", templates.opencode_instructions);

    // .cursor/rules/
    try cwd.createDirPath(io, ".cursor/rules");
    var cursor_dir = try cwd.openDir(io, ".cursor/rules", .{});
    defer cursor_dir.close(io);
    try writeFile(cursor_dir, "zfinal.mdc", templates.cursor_rules);

    // .github/workflows/ — CI/CD template
    try cwd.createDirPath(io, ".github/workflows");
    var gh_dir = try cwd.openDir(io, ".github/workflows", .{});
    defer gh_dir.close(io);
    try writeFile(gh_dir, "test.yml", templates.github_workflow_test);
}

/// Copy framework skill files from sibling repo to project's .claude/skills/.
/// Source: tries CWD and walks up to 5 parent directories to find
/// the zfinal framework root.
fn copyFrameworkSkills(allocator: std.mem.Allocator, dest_dir: std.Io.Dir) void {
    var candidates: [6][]const u8 = undefined;
    var n: usize = 0;
    candidates[n] = ".claude/skills";
    n += 1;
    candidates[n] = "../.claude/skills";
    n += 1;
    candidates[n] = "../../.claude/skills";
    n += 1;
    candidates[n] = "../../../.claude/skills";
    n += 1;
    candidates[n] = "../../../../.claude/skills";
    n += 1;
    candidates[n] = "../../../../../.claude/skills";
    n += 1;

    var src_dir_opt: ?std.Io.Dir = null;
    var found_path: ?[]const u8 = null;
    for (candidates[0..n]) |path| {
        if (std.Io.Dir.cwd().openDir(io, path, .{})) |d| {
            src_dir_opt = d;
            found_path = path;
            break;
        } else |_| {}
    }
    const src_dir = src_dir_opt orelse {
        std.debug.print("  ! framework skills not found — run zf from zfinal repo root\n", .{});
        return;
    };
    defer std.Io.Dir.close(src_dir, io);
    std.debug.print("  (skills from {s})\n", .{found_path.?});

    for (framework_skill_names) |name| {
        const file = src_dir.openFile(io, name, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        if (stat.size > 100_000) continue;
        const content = allocator.alloc(u8, @intCast(stat.size)) catch continue;
        defer allocator.free(content);
        _ = std.Io.File.readPositionalAll(file, io, content, 0) catch continue;
        writeFile(dest_dir, name, content) catch continue;
        std.debug.print("  ✓ skill: {s}\n", .{name});
    }
}
