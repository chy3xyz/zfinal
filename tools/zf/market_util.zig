//! Pure helpers for the module marketplace (phase 2, ADR-016).
//! No I/O in this file — everything here is unit-testable.
const std = @import("std");

pub const default_registry_url = "https://raw.githubusercontent.com/chy3xyz/zfinal/main/marketplace/catalog.json";

/// Local cache path for the remote catalog: `$XDG_CACHE_HOME/zf/...` or `$HOME/.cache/zf/...`.
/// Caller owns the returned memory.
pub fn cachePath(allocator: std.mem.Allocator, home: ?[]const u8, xdg_cache: ?[]const u8) ![]u8 {
    const base_owned = if (xdg_cache) |x| x else if (home) |h| blk: {
        break :blk try std.fmt.allocPrint(allocator, "{s}/.cache", .{h});
    } else return error.HomeNotFound;
    defer if (xdg_cache == null) allocator.free(base_owned);
    return std.fmt.allocPrint(allocator, "{s}/zf/marketplace-catalog.json", .{base_owned});
}

/// Number of leading path components to strip when extracting an artifact tarball.
/// GitHub archive tarballs carry one top-level prefix dir (`repo-tag/`), so 1
/// component is stripped when the first entry has any slash; flat layouts keep 0.
pub fn computeStripComponents(first_name: []const u8) u32 {
    var has_slash = false;
    for (first_name) |c| {
        if (c == '/') {
            has_slash = true;
            break;
        }
    }
    return if (has_slash) 1 else 0;
}

/// Destination for an installed module.
/// - `kind: plugin` → `src/plugin/<basename(id)>`
/// - `explicit_dir` set → `<dir>/<id>` (examples/modules)
/// - default → `vendor/marketplace/<id>`
/// Caller owns the returned memory.
pub fn installDestFor(allocator: std.mem.Allocator, id: []const u8, kind: []const u8, explicit_dir: ?[]const u8) ![]u8 {
    if (std.mem.eql(u8, kind, "plugin")) {
        return std.fmt.allocPrint(allocator, "src/plugin/{s}", .{basename(id)});
    }
    if (explicit_dir) |dir| {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, id });
    }
    return std.fmt.allocPrint(allocator, "vendor/marketplace/{s}", .{id});
}

/// Locate a module entry by `id` inside a parsed catalog document.
pub fn findEntry(parsed: *const std.json.Value, id: []const u8) ?std.json.Value {
    const modules = parsed.object.get("modules") orelse return null;
    for (modules.array.items) |item| {
        const mid = item.object.get("id") orelse continue;
        if (std.mem.eql(u8, mid.string, id)) return item;
    }
    return null;
}

/// The `url` field of a module entry, or null when the entry has no remote artifact.
pub fn entryUrl(entry: std.json.Value) ?[]const u8 {
    const u = entry.object.get("url") orelse return null;
    return u.string;
}

/// Case-insensitive substring match against id / name / summary / tags.
/// Null query matches everything.
pub fn matchQuery(item: std.json.Value, query: ?[]const u8) bool {
    const q = query orelse return true;
    const id = item.object.get("id").?.string;
    const name = item.object.get("name").?.string;
    const summary = item.object.get("summary").?.string;
    if (containsIgnoreCase(id, q)) return true;
    if (containsIgnoreCase(name, q)) return true;
    if (containsIgnoreCase(summary, q)) return true;
    if (item.object.get("tags")) |tags| {
        for (tags.array.items) |t| {
            if (containsIgnoreCase(t.string, q)) return true;
        }
    }
    return false;
}

fn basename(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "computeStripComponents: github prefix strips one" {
    try std.testing.expectEqual(@as(u32, 1), computeStripComponents("zfinal-v0.20.3/examples/zent-shop/main.zig"));
    try std.testing.expectEqual(@as(u32, 1), computeStripComponents("myrepo-1.0.0/src/plugin/x.zig"));
}

test "computeStripComponents: flat layout strips none" {
    try std.testing.expectEqual(@as(u32, 0), computeStripComponents("main.zig"));
    try std.testing.expectEqual(@as(u32, 0), computeStripComponents("README.md"));
}

test "installDestFor: example goes under vendor/marketplace" {
    const a = std.testing.allocator;
    const d = try installDestFor(a, "example/zent-shop", "example", null);
    defer a.free(d);
    try std.testing.expectEqualStrings("vendor/marketplace/example/zent-shop", d);
}

test "installDestFor: explicit dir wins" {
    const a = std.testing.allocator;
    const d = try installDestFor(a, "example/zent-shop", "example", "tmp/proj");
    defer a.free(d);
    try std.testing.expectEqualStrings("tmp/proj/example/zent-shop", d);
}

test "installDestFor: plugin basename goes to src/plugin" {
    const a = std.testing.allocator;
    const d = try installDestFor(a, "plugin/metrics", "plugin", null);
    defer a.free(d);
    try std.testing.expectEqualStrings("src/plugin/metrics", d);
}

test "cachePath: XDG overrides HOME" {
    const a = std.testing.allocator;
    const p = try cachePath(a, "/Users/me", "/Users/me/.cache");
    defer a.free(p);
    try std.testing.expectEqualStrings("/Users/me/.cache/zf/marketplace-catalog.json", p);
}

test "cachePath: HOME fallback" {
    const a = std.testing.allocator;
    const p = try cachePath(a, "/Users/me", null);
    defer a.free(p);
    try std.testing.expectEqualStrings("/Users/me/.cache/zf/marketplace-catalog.json", p);
}

test "findEntry: matches by id" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        "{\"modules\":[{\"id\":\"example/hello-world\",\"url\":\"https://x/t.tgz\"}]}", .{});
    defer parsed.deinit();
    const e = findEntry(&parsed.value, "example/hello-world").?;
    try std.testing.expectEqualStrings("https://x/t.tgz", entryUrl(e).?);
    try std.testing.expect(findEntry(&parsed.value, "nope") == null);
}

test "matchQuery: case-insensitive across id/name/summary/tags" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        "{\"modules\":[{\"id\":\"example/zent-shop\",\"name\":\"Zent Shop\",\"summary\":\"e-commerce\",\"tags\":[\"zent\"]}]}", .{});
    defer parsed.deinit();
    const item = parsed.value.object.get("modules").?.array.items[0];
    try std.testing.expect(matchQuery(item, "ZENT"));
    try std.testing.expect(matchQuery(item, "commerce"));
    try std.testing.expect(!matchQuery(item, "nope"));
    try std.testing.expect(matchQuery(item, null));
}
