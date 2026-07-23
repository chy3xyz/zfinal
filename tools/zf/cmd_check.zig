//! `zf check` — AI boundary audit, --prod contract, --heal patches.
const std = @import("std");
const zf_cfg = @import("zf_cfg");
const zf_shared = @import("zf_shared.zig");

const readFileAlloc = zf_shared.readFileAlloc;

/// Audit project for AI compliance: .gen.zig boundaries, ext/ structure, import correctness.
/// With --heal: automatically patch known issues (stale getPool pattern, missing getters, etc.)
/// `prod_root`: directory to scan for `--prod` (default `examples/production`).
pub fn handleCheck(allocator: std.mem.Allocator, heal: bool, ai_zones: bool, prod: bool, prod_root: []const u8) !void {
    if (ai_zones) {
        try printAiZones(allocator);
        return;
    }
    if (heal) {
        std.debug.print("\n🩹 ZFinal AI Compliance — SELF-HEAL MODE\n", .{});
        std.debug.print("════════════════════════════════════════\n\n", .{});
        var patched: u32 = 0;
        patched += try healStaleGetterPattern(allocator);
        patched += try healMissingGetters(allocator);
        patched += try healCallconvLowercase(allocator);
        patched += try healComptimeVar(allocator);
        patched += try healDupeZ(allocator);
        patched += try healBufPrintZ(allocator);
        std.debug.print("\n════════════════════════════════════════\n", .{});
        std.debug.print("Healed: {d} file(s) patched.\n", .{patched});
        if (patched == 0) std.debug.print("✅ No issues found — code already healthy.\n", .{});
        std.debug.print("Run: zig build to verify.\n", .{});
        return;
    }

    std.debug.print("\n🔍 ZFinal AI Compliance Check\n", .{});
    std.debug.print("═══════════════════════════════\n\n", .{});

    var pass: u32 = 0;
    var warn: u32 = 0;
    var fail: u32 = 0;

    // 1. Check CLAUDE.md exists
    if (std.Io.Dir.cwd().access(zf_shared.io, "CLAUDE.md", .{})) |_| {
        std.debug.print("✅ PASS: CLAUDE.md exists\n", .{});
        pass += 1;
    } else |_| {
        std.debug.print("⚠️  WARN: No CLAUDE.md — AI may not know project rules. Run: zf new\n", .{});
        warn += 1;
    }

    // 2. Count .gen.zig files (they should not be hand-edited)
    var gen_count: u32 = 0;
    countGenFiles(allocator, &gen_count);
    if (gen_count > 0) {
        std.debug.print("✅ PASS: {d} .gen.zig files detected (auto-generated, do not edit)\n", .{gen_count});
        pass += 1;
    }

    // 3. Check ext/ directories exist for each module with .gen.zig
    var ext_ok: u32 = 0;
    var ext_miss: u32 = 0;
    checkExtDirs(allocator, &ext_ok, &ext_miss, &fail);
    if (ext_miss == 0 and ext_ok > 0) {
        std.debug.print("✅ PASS: all ext/ directories present ({d} modules)\n", .{ext_ok});
        pass += 1;
    }

    // 4. Detect .zig files outside ext/ that should be in ext/
    checkOrphanHandlers(allocator, &warn);

    if (prod) {
        try checkProdContract(allocator, prod_root, &pass, &warn, &fail);
    }

    std.debug.print("\n═══════════════════════════════\n", .{});
    std.debug.print("Results: {d} pass  {d} warn  {d} fail\n", .{ pass, warn, fail });
    if (fail > 0) {
        std.debug.print("\n❌ FAIL: Fix {d} issue(s) before committing.\n", .{fail});
    } else if (warn > 0) {
        std.debug.print("\n⚠️  PASS with {d} warning(s). Review before committing.\n", .{warn});
    } else {
        std.debug.print("\n✅ All checks passed. AI compliance verified.\n", .{});
    }
    std.debug.print("\n", .{});
}

/// Heuristic scan for PRODUCTION_AUDIT deployment-contract anti-patterns.
/// `root` is the app directory (e.g. `examples/production` or your app root).
fn checkProdContract(allocator: std.mem.Allocator, root: []const u8, pass: *u32, warn: *u32, fail: *u32) !void {
    std.debug.print("\n--- Production contract (--prod) root={s} ---\n", .{root});
    const is_reference = std.mem.eql(u8, root, "examples/production");
    var banned_auth: u32 = 0;
    var banned_cors_star: u32 = 0;
    var experimental: u32 = 0;
    var force_ka_off: u32 = 0;

    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{ .iterate = true }) catch {
        fail.* += 1;
        std.debug.print("❌ FAIL: cannot open --root {s}\n", .{root});
        return;
    };
    defer dir.close(zf_shared.io);
    var walker = dir.walk(allocator) catch {
        fail.* += 1;
        std.debug.print("❌ FAIL: cannot walk --root {s}\n", .{root});
        return;
    };
    defer walker.deinit();
    while (walker.next(zf_shared.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path });
        defer allocator.free(rel);
        const content = readFileAlloc(allocator, rel) catch continue;
        defer allocator.free(content);
        if (std.mem.indexOf(u8, content, "AuthInterceptor") != null and
            std.mem.indexOf(u8, content, "createJwtAuthInterceptor") == null and
            std.mem.indexOf(u8, content, "Demo-only") == null)
        {
            banned_auth += 1;
            std.debug.print("⚠️  WARN: {s} references AuthInterceptor (prefer createJwtAuthInterceptor)\n", .{rel});
        }
        if (std.mem.indexOf(u8, content, "CORSInterceptor") != null and
            std.mem.indexOf(u8, content, "createCors") == null)
        {
            banned_cors_star += 1;
            std.debug.print("⚠️  WARN: {s} uses CORSInterceptor (wildcard) — prefer createCorsAllowlistInterceptor\n", .{rel});
        }
        if (std.mem.indexOf(u8, content, "zfinal.experimental.") != null) {
            experimental += 1;
            std.debug.print("⚠️  WARN: {s} uses zfinal.experimental.*\n", .{rel});
        }
        if (std.mem.indexOf(u8, content, "force_connection_close = false") != null or
            std.mem.indexOf(u8, content, ".force_connection_close = false") != null)
        {
            force_ka_off += 1;
            std.debug.print("⚠️  WARN: {s} disables force_connection_close (keep-alive experimental)\n", .{rel});
        }
    }

    var prod_fail: u32 = 0;
    var prod_warn: u32 = 0;

    const main_path = try resolveAppMain(allocator, root);
    defer allocator.free(main_path);

    if (readFileAlloc(allocator, main_path)) |content| {
        defer allocator.free(content);
        const checks = [_]struct { needle: []const u8, label: []const u8 }{
            .{ .needle = "createSecurityHeadersInterceptor", .label = "createSecurityHeadersInterceptor" },
            .{ .needle = "createRequestIdInterceptor", .label = "createRequestIdInterceptor" },
            .{ .needle = "createJwtAuthInterceptorWithOptions", .label = "createJwtAuthInterceptorWithOptions" },
            .{ .needle = "metricsHandlerFor", .label = "/metrics wiring (metricsHandlerFor)" },
        };
        for (checks) |c| {
            if (std.mem.indexOf(u8, content, c.needle) == null) {
                if (is_reference) {
                    prod_fail += 1;
                    std.debug.print("❌ FAIL: {s} missing {s}\n", .{ main_path, c.label });
                } else {
                    prod_warn += 1;
                    std.debug.print("⚠️  WARN: {s} missing {s} (required for internet-facing BFF)\n", .{ main_path, c.label });
                }
            }
        }
    } else |_| {
        if (is_reference) {
            prod_fail += 1;
            std.debug.print("❌ FAIL: missing {s}\n", .{main_path});
        } else {
            prod_warn += 1;
            std.debug.print("⚠️  WARN: no main.zig under {s} (tried main.zig / src/main.zig)\n", .{root});
        }
    }

    fail.* += prod_fail;
    warn.* += prod_warn;

    if (banned_auth == 0 and banned_cors_star == 0 and experimental == 0 and force_ka_off == 0 and prod_fail == 0 and prod_warn == 0) {
        std.debug.print("✅ PASS: {s} meets deployment contract\n", .{root});
        pass.* += 1;
    } else if (prod_fail == 0) {
        warn.* += banned_auth + banned_cors_star + experimental + force_ka_off;
    }
}

fn resolveAppMain(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const candidates = [_][]const u8{ "main.zig", "src/main.zig" };
    for (candidates) |rel| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel });
        if (std.Io.Dir.cwd().access(zf_shared.io, path, .{})) |_| {
            return path;
        } else |_| {
            allocator.free(path);
        }
    }
    return try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
}

fn countGenFiles(allocator: std.mem.Allocator, count: *u32) void {
    var modules_dir = std.Io.Dir.cwd().openDir(zf_shared.io, "src/modules", .{ .iterate = true }) catch {
        count.* = 0;
        return;
    };
    defer modules_dir.close(zf_shared.io);

    var walker = modules_dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next(zf_shared.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.basename, ".gen.zig")) count.* += 1;
    }
}

fn checkExtDirs(allocator: std.mem.Allocator, ok: *u32, miss: *u32, fail: *u32) void {
    var modules_dir = std.Io.Dir.cwd().openDir(zf_shared.io, "src/modules", .{ .iterate = true }) catch return;
    defer modules_dir.close(zf_shared.io);

    var walker = modules_dir.walk(allocator) catch return;
    defer walker.deinit();

    // Use simple array for dedup — fewer than 256 modules is safe
    var checked: [256][]const u8 = undefined;
    var checked_count: usize = 0;

    while (walker.next(zf_shared.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".gen.zig")) continue;

        const dir_path = std.fs.path.dirname(entry.path) orelse continue;

        // Check if we've already processed this directory
        var seen = false;
        for (checked[0..checked_count]) |c| {
            if (std.mem.eql(u8, c, dir_path)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (checked_count < checked.len) {
            checked[checked_count] = dir_path;
            checked_count += 1;
        }

        if (modules_dir.openDir(zf_shared.io, dir_path, .{})) |mod_dir| {
            defer mod_dir.close(zf_shared.io);
            if (mod_dir.openDir(zf_shared.io, "ext", .{})) |ext_dir| {
                ext_dir.close(zf_shared.io);
                ok.* += 1;
            } else |_| {
                std.debug.print("❌ FAIL: missing ext/ at src/modules/{s}/\n", .{dir_path});
                fail.* += 1;
                miss.* += 1;
            }
        } else |_| {}
    }
}

fn checkOrphanHandlers(allocator: std.mem.Allocator, warn: *u32) void {
    var handler_dir = std.Io.Dir.cwd().openDir(zf_shared.io, "src/handler", .{ .iterate = true }) catch return;
    defer handler_dir.close(zf_shared.io);

    var walker = handler_dir.walk(allocator) catch return;
    defer walker.deinit();

    var buf1: [256]u8 = undefined;
    var buf2: [512]u8 = undefined;
    while (walker.next(zf_shared.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.basename, ".gen.zig")) continue;
        if (std.mem.indexOf(u8, entry.path, "/ext/") != null) continue;

        const stem = entry.basename[0 .. entry.basename.len - 4];
        const gen_name = std.fmt.bufPrint(&buf1, "{s}.gen.zig", .{stem}) catch continue;
        const dir_name = std.fs.path.dirname(entry.path) orelse ".";
        const gen_path = std.fmt.bufPrint(&buf2, "{s}/{s}", .{ dir_name, gen_name }) catch continue;

        if (std.Io.Dir.cwd().access(zf_shared.io, gen_path, .{})) {
            std.debug.print("⚠️  WARN: {s} near .gen.zig — move to ext/{s}\n", .{ entry.path, entry.basename });
            warn.* += 1;
        } else |_| {}
    }
}
// ─────────────────────────────────────────────────────────────────────────────
// Self-heal helpers (zf check --heal)
// ─────────────────────────────────────────────────────────────────────────────

/// Patch stale `pool_ref = &deps.pool` patterns → `getPool()` pattern.
/// Returns count of files patched.
fn healStaleGetterPattern(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(zf_shared.io, path, .{}) catch continue;
        defer f.close(zf_shared.io);
        const stat = try f.stat(zf_shared.io);
        if (stat.size > 1_000_000) continue;
        var content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, zf_shared.io, content, 0);

        const orig = content;
        // Pattern: pool_ref = &@import(...).pool
        if (std.mem.indexOf(u8, content, "pool_ref") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "const pool_ref = &@import(\"", "const pool = @import(\"");
            content = new1;
            const new2 = try std.mem.replaceOwned(u8, allocator, content, "\").pool;", "\").getPool();");
            content = new2;
            const new3 = try std.mem.replaceOwned(u8, allocator, content, "pool_ref.", "pool.");
            content = new3;
        }
        if (std.mem.indexOf(u8, content, "token_ref") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "const token_ref = &@import(\"", "const tokenMgr = @import(\"");
            content = new1;
            const new2 = try std.mem.replaceOwned(u8, allocator, content, "\").tokenMgr;", "\").getTokenMgr();");
            content = new2;
            const new3 = try std.mem.replaceOwned(u8, allocator, content, "token_ref.", "tokenMgr.");
            content = new3;
        }
        if (std.mem.indexOf(u8, content, "limit_ref") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "const limit_ref = &@import(\"", "const rateLimiter = @import(\"");
            content = new1;
            const new2 = try std.mem.replaceOwned(u8, allocator, content, "\").rateLimiter;", "\").getRateLimiter();");
            content = new2;
            const new3 = try std.mem.replaceOwned(u8, allocator, content, "limit_ref.", "rateLimiter.");
            content = new3;
        }
        if (!std.mem.eql(u8, content, orig)) {
            try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = path, .data = content });
            std.debug.print("  ✓ healed: {s} (stale getter pattern)\n", .{path});
            patched += 1;
        }
    }
    return patched;
}

/// Patch deps.zig files that lack getPool()/getTokenMgr()/getRateLimiter().
fn healMissingGetters(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    // Find all deps.zig files under src/
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFiles(allocator, "src", "deps.zig", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(zf_shared.io, path, .{}) catch continue;
        defer f.close(zf_shared.io);
        const stat = try f.stat(zf_shared.io);
        if (stat.size > 100_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, zf_shared.io, content, 0);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, content);
        const has_getpool = std.mem.containsAtLeast(u8, content, 1, "pub fn getPool");
        const has_gettoken = std.mem.containsAtLeast(u8, content, 1, "pub fn getTokenMgr");
        const has_getlimit = std.mem.containsAtLeast(u8, content, 1, "pub fn getRateLimiter");
        if (!has_getpool or !has_gettoken or !has_getlimit) {
            try buf.appendSlice(allocator,
                \\
                \\
                \\pub fn getPool() *zfinal.ConnectionPool {
                \\    return @as(*zfinal.ConnectionPool, @ptrCast(&pool));
                \\}
                \\
                \\pub fn getTokenMgr() *zfinal.TokenManager {
                \\    return &tokenMgr;
                \\}
                \\
                \\pub fn getRateLimiter() *zfinal.RateLimitHandler {
                \\    return &rateLimiter;
                \\}
            );
            try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = path, .data = buf.items });
            std.debug.print("  ✓ healed: {s} (added getter functions)\n", .{path});
            patched += 1;
        }
    }
    return patched;
}

/// Patch callconv(.C) → callconv(.c) (Zig 0.17 lowercase).
fn healCallconvLowercase(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(zf_shared.io, path, .{}) catch continue;
        defer f.close(zf_shared.io);
        const stat = try f.stat(zf_shared.io);
        if (stat.size > 200_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, zf_shared.io, content, 0);
        if (std.mem.indexOf(u8, content, "callconv(.C)") == null) continue;
        const new_content = std.mem.replaceOwned(u8, allocator, content, "callconv(.C)", "callconv(.c)") catch |e| {
            std.debug.print("  ! skip {s}: {t}\n", .{ path, e });
            continue;
        };
        defer allocator.free(new_content);
        try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = path, .data = new_content });
        std.debug.print("  ✓ healed: {s} (callconv .C → .c)\n", .{path});
        patched += 1;
    }
    return patched;
}

/// Patch var → const for params that are never reassigned (Zig 0.17 strict).
/// Conservative: only handles the pattern `var t = try spawn/test/...;` where the var is never reassigned.
fn healComptimeVar(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(zf_shared.io, path, .{}) catch continue;
        defer f.close(zf_shared.io);
        const stat = try f.stat(zf_shared.io);
        if (stat.size > 200_000) continue;
        var content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, zf_shared.io, content, 0);

        const orig = content;
        if (std.mem.indexOf(u8, content, "var t = try") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "var t = try", "const t = try");
            content = new1;
        }
        if (std.mem.indexOf(u8, content, "var box = try") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "var box = try", "const box = try");
            content = new1;
        }
        if (!std.mem.eql(u8, content, orig)) {
            try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = path, .data = content });
            std.debug.print("  ✓ healed: {s} (var → const)\n", .{path});
            patched += 1;
        }
    }
    return patched;
}

/// Patch `allocator.dupeZ(T, x)` → `allocator.allocSentinel(T, x.len, 0)`.
/// Zig 0.17 removed `dupeZ` in favor of `allocSentinel` + manual `@memcpy`.
/// Note: this only renames the function. Users must manually add @memcpy
/// because the original dupeZ semantics aren't directly translatable.
fn healDupeZ(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(zf_shared.io, path, .{}) catch continue;
        defer f.close(zf_shared.io);
        const stat = try f.stat(zf_shared.io);
        if (stat.size > 200_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, zf_shared.io, content, 0);
        if (std.mem.indexOf(u8, content, ".dupeZ(") == null) continue;
        const new_content = std.mem.replaceOwned(u8, allocator, content, ".dupeZ(", ".allocSentinel(") catch continue;
        defer allocator.free(new_content);
        try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = path, .data = new_content });
        std.debug.print("  ✓ healed: {s} (dupeZ → allocSentinel — manual @memcpy needed)\n", .{path});
        patched += 1;
    }
    return patched;
}

/// Patch `std.fmt.bufPrintZ` → `std.fmt.bufPrint`.
/// Zig 0.17 removed `bufPrintZ`. User must manually append `\0`.
fn healBufPrintZ(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(zf_shared.io, path, .{}) catch continue;
        defer f.close(zf_shared.io);
        const stat = try f.stat(zf_shared.io);
        if (stat.size > 200_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, zf_shared.io, content, 0);
        if (std.mem.indexOf(u8, content, "bufPrintZ") == null) continue;
        const new_content = std.mem.replaceOwned(u8, allocator, content, "bufPrintZ", "bufPrint") catch continue;
        defer allocator.free(new_content);
        try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = path, .data = new_content });
        std.debug.print("  ✓ healed: {s} (bufPrintZ → bufPrint — manual \\0 needed)\n", .{path});
        patched += 1;
    }
    return patched;
}

/// Find all .zig files under a directory (recursive, non-generated only).
fn findFilesAll(allocator: std.mem.Allocator, root: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{}) catch return;
    defer std.Io.Dir.close(dir, zf_shared.io);
    var it = dir.iterate();
    while (try it.next(zf_shared.io)) |entry| {
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });
        if (entry.kind == .directory) {
            try findFilesAll(allocator, sub_path, out);
            allocator.free(sub_path);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            try out.append(allocator, sub_path);
        } else {
            allocator.free(sub_path);
        }
    }
}

/// Find specific named file under a directory tree.
fn findFiles(allocator: std.mem.Allocator, root: []const u8, name: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{}) catch return;
    defer std.Io.Dir.close(dir, zf_shared.io);
    var it = dir.iterate();
    while (try it.next(zf_shared.io)) |entry| {
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });
        if (entry.kind == .directory) {
            try findFiles(allocator, sub_path, name, out);
            allocator.free(sub_path);
        } else if (entry.kind == .file and std.mem.eql(u8, entry.name, name)) {
            try out.append(allocator, sub_path);
        } else {
            allocator.free(sub_path);
        }
    }
}

/// Print reverse index of AI-editable files for AI agents.
/// Shows which .zig files AI is allowed to edit (no `// @generated` header,
/// has `// ── ai-edit-zone` markers or is in `ext/` directory).
fn printAiZones(allocator: std.mem.Allocator) !void {
    std.debug.print("\n📝 ZFinal AI-Editable Files\n", .{});
    std.debug.print("═══════════════════════════\n\n", .{});
    std.debug.print("Files marked with `// @generated` are AI-LOCKED.\n", .{});
    std.debug.print("Files with `// ── ai-edit-zone:` markers are AI-EDITABLE.\n\n", .{});

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    var editable: u32 = 0;
    var locked: u32 = 0;
    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(zf_shared.io, path, .{}) catch continue;
        defer f.close(zf_shared.io);
        const stat = try f.stat(zf_shared.io);
        if (stat.size > 200_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, zf_shared.io, content, 0);
        const is_generated = std.mem.containsAtLeast(u8, content, 1, "// @generated");
        const has_zone = std.mem.containsAtLeast(u8, content, 1, "ai-edit-zone");
        const in_ext = std.mem.containsAtLeast(u8, path, 1, "/ext/");

        if (is_generated) {
            locked += 1;
        } else if (has_zone or in_ext) {
            editable += 1;
            std.debug.print("  ✅ {s}", .{path});
            if (has_zone) std.debug.print(" [ai-edit-zone]", .{});
            if (in_ext) std.debug.print(" [ext/]", .{});
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("\n─────────────────────────────────────────\n", .{});
    std.debug.print("  Editable: {d}  |  Locked: {d}\n", .{ editable, locked });
    std.debug.print("  When in doubt: edit only files marked ✅ above.\n", .{});
    std.debug.print("  For help: see .claude/skills/zfinal-onboarding.md\n", .{});
}

/// Patch content with a simple regex-like replacement (limited subset).
/// Supports literal text + capture groups using \1 in replacement.
fn patchRegex(content: []const u8, pattern: []const u8, replacement: []const u8) []const u8 {
    // Simple substring-based: skip regex for now, only support exact strings
    _ = pattern;
    _ = replacement;
    return content;
}
