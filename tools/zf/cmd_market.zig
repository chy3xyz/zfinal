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
    if (@backingInt(result.status) < 200 or @backingInt(result.status) >= 300) {
        std.debug.print("   (HTTP {d})\n", .{@backingInt(result.status)});
        return error.FetchFailed;
    }
    try body.appendSlice(allocator, response_writer.buffer[0..response_writer.end]);
}

pub const InstallOptions = struct {
    explicit_dir: ?[]const u8 = null,
    dry_run: bool = false,
    verify: bool = false,
};

/// `zf market install <id>` — download the entry's artifact tarball, extract its
/// `path` subdir, and place it (plugin → src/plugin/, example|module → vendor/marketplace/<id>/).
pub fn handleInstall(allocator: std.mem.Allocator, catalog_path: ?[]const u8, id: []const u8, opts: InstallOptions) !void {
    var parsed = try loadCatalogSource(allocator, catalog_path);
    defer parsed.deinit();
    const entry = market_util.findEntry(&parsed.value, id) orelse {
        std.debug.print("❌ module id not found: {s}\n", .{id});
        return error.ModuleNotFound;
    };
    const url = market_util.entryUrl(entry) orelse {
        std.debug.print("❌ module '{s}' has no remote artifact (url missing)\n", .{id});
        return error.NoRemoteArtifact;
    };
    const kind = entry.object.get("kind").?.string;
    const path = entry.object.get("path").?.string;

    var dest_owned: []u8 = undefined;
    if (std.mem.eql(u8, kind, "plugin")) {
        dest_owned = try std.fmt.allocPrint(allocator, "src/plugin/{s}", .{market_util.basenameOf(path)});
    } else {
        dest_owned = try market_util.installDestFor(allocator, id, kind, opts.explicit_dir);
    }
    defer allocator.free(dest_owned);
    const dest = dest_owned;

    std.debug.print("📦 Install {s} [{s}]\n", .{ id, kind });
    std.debug.print("   url:  {s}\n", .{url});
    std.debug.print("   path: {s}\n", .{path});
    std.debug.print("   dest: {s}\n", .{dest});

    if (opts.dry_run) {
        std.debug.print("   (dry-run — no changes made)\n", .{});
        return;
    }

    // 1. Download the artifact tarball into memory.
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try fetchCatalog(allocator, url, &body);
    if (body.items.len == 0) return error.EmptyArtifact;

    // 2. Decompress gzip → tar and extract into a temp dir (no strip; the
    //    archive prefix dir is resolved afterwards via moduleSrcIn).
    const tmp_name = try std.fmt.allocPrint(allocator, ".zf-market-tmp-{d}", .{std.Io.Timestamp.now(zf_shared.io, .real).toSeconds()});
    defer allocator.free(tmp_name);
    defer std.Io.Dir.cwd().deleteTree(zf_shared.io, tmp_name) catch {};

    var tmp_dir = try std.Io.Dir.cwd().createDirPathOpen(zf_shared.io, tmp_name, .{});
    defer tmp_dir.close(zf_shared.io);

    {
        var input_reader = std.Io.Reader.fixed(body.items);
        var win_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&input_reader, .gzip, &win_buf);
        try std.tar.extract(zf_shared.io, tmp_dir, &decomp.reader, .{});
    }

    // 3. Locate the module source inside the extracted tree, skipping one
    //    leading archive prefix dir when present (e.g. `zfinal-v0.20.3/`).
    const module_src = try moduleSrcIn(allocator, tmp_dir, path);
    defer allocator.free(module_src);

    // 4. Ensure the destination parent exists, then move the module into place.
    if (std.mem.lastIndexOfScalar(u8, dest, '/')) |slash| {
        try zf_shared.ensureDir(allocator, dest[0..slash]);
    }
    tmp_dir.rename(module_src, std.Io.Dir.cwd(), dest, zf_shared.io) catch |err| {
        std.debug.print("❌ failed to place module (dest may already exist): {t}\n", .{err});
        return err;
    };
    std.debug.print("✅ Installed → {s}\n", .{dest});

    if (opts.verify) {
        std.debug.print("   Verifying: zig build\n", .{});
        const r = std.process.run(allocator, zf_shared.io, .{ .argv = &.{ "zig", "build" } }) catch |err| {
            std.debug.print("   ⚠️ zig build failed to run: {t}\n", .{err});
            return;
        };
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (r.term == .exited and r.term.exited == 0) {
            std.debug.print("   ✅ zig build ok\n", .{});
        } else {
            std.debug.print("   ❌ zig build failed:\n{s}\n", .{r.stderr});
        }
    }
}

/// Resolve `path` inside an extracted `dir`, skipping one leading archive
/// prefix directory when present (GitHub archives are `<repo>-<tag>/...`).
/// Returns a caller-owned path.
fn moduleSrcIn(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var it = dir.iterate();
    var prefix: ?[]const u8 = null;
    while (try it.next(zf_shared.io)) |entry| {
        if (entry.kind == .directory and prefix == null) {
            prefix = entry.name;
        }
    }
    if (prefix) |p| {
        const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ p, path });
        if (dir.access(zf_shared.io, joined, .{})) |_| {
            return joined;
        } else |_| {
            allocator.free(joined);
        }
    }
    return allocator.dupe(u8, path);
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
            if (!market_util.matchQuery(item, query)) continue;
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
        if (!market_util.matchQuery(item, query)) continue;
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
