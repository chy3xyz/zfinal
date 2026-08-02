//! `zf market` — module marketplace (phase 2: local catalog + remote index/install, ADR-016).
const std = @import("std");
const zf_shared = @import("zf_shared.zig");
const market_util = @import("market_util.zig");

const default_catalog = "marketplace/catalog.json";

pub fn handleMarket(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3 or zf_shared.hasFlag(args, "-h") or zf_shared.hasFlag(args, "--help")) {
        printHelp(args[0]);
        return;
    }
    const sub = args[2];
    const json_mode = zf_shared.hasFlag(args, "--json");
    const catalog_path = zf_shared.flagValue(args, "--catalog");

    if (std.mem.eql(u8, sub, "update")) {
        const registry = zf_shared.flagValue(args, "--registry") orelse market_util.default_registry_url;
        try handleUpdate(allocator, registry);
    } else if (std.mem.eql(u8, sub, "install")) {
        if (args.len < 4) {
            std.debug.print("Usage: {s} market install <id> [--dir DIR] [--dry-run] [--verify]\n", .{args[0]});
            return;
        }
        try handleInstall(allocator, catalog_path, args[3], .{
            .explicit_dir = zf_shared.flagValue(args, "--dir"),
            .dry_run = zf_shared.hasFlag(args, "--dry-run"),
            .verify = zf_shared.hasFlag(args, "--verify"),
        });
    } else if (std.mem.eql(u8, sub, "list")) {
        try listOrSearch(allocator, catalog_path, null, json_mode);
    } else if (std.mem.eql(u8, sub, "search")) {
        if (args.len < 4) {
            std.debug.print("Usage: {s} market search <query> [--json]\n", .{args[0]});
            return;
        }
        try listOrSearch(allocator, catalog_path, args[3], json_mode);
    } else if (std.mem.eql(u8, sub, "info")) {
        if (args.len < 4) {
            std.debug.print("Usage: {s} market info <id> [--json]\n", .{args[0]});
            return;
        }
        try infoOne(allocator, catalog_path, args[3], json_mode);
    } else {
        std.debug.print("Unknown market subcommand: {s}\n", .{sub});
        printHelp(args[0]);
    }
}

fn printHelp(exe: []const u8) void {
    std.debug.print(
        \\Usage: {s} market <list|search|info|update|install> [args] [--json] [--catalog PATH] [--registry URL]
        \\  Phase 2 (ADR-016): local catalog + remote index/install.
        \\    update    sync remote catalog → ~/.cache/zf/marketplace-catalog.json
        \\    install   <id> [--dir DIR] [--dry-run] [--verify]
        \\  See doc/module_marketplace.md
        \\
    , .{exe});
}

/// Resolve the catalog source with cache-first priority:
/// explicit --catalog > cache file > repo-local marketplace/catalog.json.
fn loadCatalogSource(allocator: std.mem.Allocator, catalog_path: ?[]const u8) !std.json.Parsed(std.json.Value) {
    if (catalog_path) |p| return loadCatalog(allocator, p);
    const home = envGet("HOME");
    const xdg = envGet("XDG_CACHE_HOME");
    const cache = try market_util.cachePath(allocator, home, xdg);
    defer allocator.free(cache);
    if (std.Io.Dir.cwd().access(zf_shared.io, cache, .{}) != error.FileNotFound) {
        std.debug.print("(catalog: {s})\n", .{cache});
        return loadCatalog(allocator, cache);
    }
    std.debug.print("(catalog: {s})\n", .{default_catalog});
    return loadCatalog(allocator, default_catalog);
}

fn envGet(key: []const u8) ?[]const u8 {
    const m = zf_shared.environ_map orelse return null;
    return m.get(key);
}

/// `zf market update` — fetch the remote catalog and cache it locally.
pub fn handleUpdate(allocator: std.mem.Allocator, registry_url: []const u8) !void {
    std.debug.print("⬇️  Syncing market catalog: {s}\n", .{registry_url});
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    fetchCatalog(allocator, registry_url, &body) catch |err| {
        std.debug.print("❌ market update failed: {t}\n", .{err});
        std.debug.print("   Falling back to local marketplace/catalog.json\n", .{});
        return;
    };
    const home = envGet("HOME");
    const xdg = envGet("XDG_CACHE_HOME");
    const cache = try market_util.cachePath(allocator, home, xdg);
    defer allocator.free(cache);
    if (std.mem.lastIndexOfScalar(u8, cache, '/')) |slash| {
        try zf_shared.ensureDir(allocator, cache[0..slash]);
    }
    try zf_shared.writeFile(std.Io.Dir.cwd(), cache, body.items);
    std.debug.print("✅ Market catalog updated → {s} ({d} bytes)\n", .{ cache, body.items.len });
}

/// GET `url` and append the response body to `body`. Fails with error.FetchFailed
/// on network errors or non-2xx status.
fn fetchCatalog(allocator: std.mem.Allocator, url: []const u8, body: *std.ArrayList(u8)) !void {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = zf_shared.io,
    };
    defer client.deinit();
    const response_buf = try allocator.alloc(u8, 8 * 1024 * 1024);
    defer allocator.free(response_buf);
    const response_writer = std.Io.Writer.fixed(response_buf);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = @constCast(&response_writer),
    }) catch |err| {
        std.debug.print("   (network error: {t})\n", .{err});
        return error.FetchFailed;
    };
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        std.debug.print("   (HTTP {d})\n", .{@intFromEnum(result.status)});
        return error.FetchFailed;
    }
    try body.appendSlice(allocator, response_writer.buffer[0..response_writer.end]);
}

pub const InstallOptions = struct {
    explicit_dir: ?[]const u8 = null,
    dry_run: bool = false,
    verify: bool = false,
};

/// `zf market install <id>` — implemented in Task 3 (download/extract/place).
pub fn handleInstall(allocator: std.mem.Allocator, catalog_path: ?[]const u8, id: []const u8, opts: InstallOptions) !void {
    _ = allocator;
    _ = catalog_path;
    _ = id;
    _ = opts;
    std.debug.print("install: not implemented yet\n", .{});
}

fn loadCatalog(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const data = zf_shared.readFileAlloc(allocator, path) catch |err| {
        std.debug.print("error: cannot read catalog {s}: {}\n", .{ path, err });
        return err;
    };
    defer allocator.free(data);
    return try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .allocate = .alloc_always });
}

fn listOrSearch(allocator: std.mem.Allocator, path: ?[]const u8, query: ?[]const u8, json_mode: bool) !void {
    var parsed = try loadCatalogSource(allocator, path);
    defer parsed.deinit();
    const modules = parsed.value.object.get("modules") orelse {
        std.debug.print("error: catalog missing modules[]\n", .{});
        return;
    };

    if (json_mode) {
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try out.writer.writeAll("{\"modules\":[");
        var first = true;
        for (modules.array.items) |item| {
            if (!matchQuery(item, query)) continue;
            if (!first) try out.writer.writeByte(',');
            first = false;
            try std.json.Stringify.value(item, .{}, &out.writer);
        }
        try out.writer.writeAll("]}\n");
        const slice = try out.toOwnedSlice();
        defer allocator.free(slice);
        var stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(zf_shared.io, slice);
        return;
    }

    var n: usize = 0;
    for (modules.array.items) |item| {
        if (!matchQuery(item, query)) continue;
        const id = item.object.get("id").?.string;
        const name = item.object.get("name").?.string;
        const kind = item.object.get("kind").?.string;
        const summary = item.object.get("summary").?.string;
        std.debug.print("{s: <40} [{s}] {s} — {s}\n", .{ id, kind, name, summary });
        n += 1;
    }
    std.debug.print("({d} modules)\n", .{n});
}

fn infoOne(allocator: std.mem.Allocator, path: ?[]const u8, id: []const u8, json_mode: bool) !void {
    var parsed = try loadCatalogSource(allocator, path);
    defer parsed.deinit();
    const modules = parsed.value.object.get("modules") orelse return;
    for (modules.array.items) |item| {
        const mid = item.object.get("id").?.string;
        if (!std.mem.eql(u8, mid, id)) continue;
        if (json_mode) {
            var out = std.Io.Writer.Allocating.init(allocator);
            defer out.deinit();
            try std.json.Stringify.value(item, .{ .whitespace = .indent_2 }, &out.writer);
            try out.writer.writeByte('\n');
            const slice = try out.toOwnedSlice();
            defer allocator.free(slice);
            var stdout = std.Io.File.stdout();
            try stdout.writeStreamingAll(zf_shared.io, slice);
        } else {
            std.debug.print("id:          {s}\n", .{mid});
            std.debug.print("name:        {s}\n", .{item.object.get("name").?.string});
            std.debug.print("kind:        {s}\n", .{item.object.get("kind").?.string});
            std.debug.print("path:        {s}\n", .{item.object.get("path").?.string});
            std.debug.print("summary:     {s}\n", .{item.object.get("summary").?.string});
            if (item.object.get("min_zfinal")) |v| std.debug.print("min_zfinal:  {s}\n", .{v.string});
            if (item.object.get("doc")) |d| std.debug.print("doc:         {s}\n", .{d.string});
            if (item.object.get("tags")) |tags| {
                std.debug.print("tags:        ", .{});
                for (tags.array.items, 0..) |t, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{t.string});
                }
                std.debug.print("\n", .{});
            }
        }
        return;
    }
    std.debug.print("error: module id not found: {s}\n", .{id});
    std.process.exit(1);
}

fn matchQuery(item: std.json.Value, query: ?[]const u8) bool {
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
