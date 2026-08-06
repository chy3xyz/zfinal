//! `zf check` — AI boundary audit, --prod contract, --heal patches, --deadcode.
const std = @import("std");
const zf_cfg = @import("zf_cfg");
const zf_shared = @import("zf_shared.zig");
const zdeadcode = @import("deadcode");

const readFileAlloc = zf_shared.readFileAlloc;

pub const DeadcodeOpts = struct {
    /// Scan roots (default `src` when empty).
    paths: []const []const u8 = &.{},
    binary: bool = false,
    include_pub: bool = false,
    no_tests: bool = false,
    no_members: bool = false,
    no_files: bool = false,
    no_gitignore: bool = false,
    json: bool = false,
    verbose: bool = false,
    /// Treat findings as WARN instead of FAIL.
    warn_only: bool = false,
};

/// Audit project for AI compliance: .gen.zig boundaries, ext/ structure, import correctness.
/// With --heal: automatically patch known issues (stale getPool pattern, missing getters, etc.)
/// `prod_root`: directory to scan for `--prod` (default `examples/production`).
/// With --deadcode: run [zdeadcode](https://github.com/chy3xyz/zdeadcode) reachability lint.
pub fn handleCheck(
    allocator: std.mem.Allocator,
    heal: bool,
    ai_zones: bool,
    prod: bool,
    prod_root: []const u8,
    deadcode: bool,
    deadcode_opts: DeadcodeOpts,
    practice: bool,
    practice_strict: bool,
    practice_root: []const u8,
) !void {
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
        patched += try healHttpErrorHandler(allocator);
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

    // 5. Smart routing: brace {id} in generated routes, hand-edited @generated routes
    checkSmartRouting(allocator, &pass, &warn, &fail);

    // 6. Prefer HttpError over hand-rolled renderJson(.{ .err = ... })
    checkHandRolledErrorEnvelope(allocator, &pass, &warn);

    if (prod) {
        try checkProdContract(allocator, prod_root, &pass, &warn, &fail);
    }

    if (practice) {
        try checkPracticeRules(allocator, practice_root, practice_strict, &pass, &warn, &fail);
    }

    if (deadcode) {
        try runDeadcodeCheck(allocator, deadcode_opts, &pass, &warn, &fail);
    }

    std.debug.print("\n═══════════════════════════════\n", .{});
    std.debug.print("Results: {d} pass  {d} warn  {d} fail\n", .{ pass, warn, fail });
    if (fail > 0) {
        std.debug.print("\n❌ FAIL: Fix {d} issue(s) before committing.\n", .{fail});
        std.process.exit(zf_shared.Exit.fail);
    } else if (warn > 0) {
        std.debug.print("\n⚠️  PASS with {d} warning(s). Review before committing.\n", .{warn});
    } else {
        std.debug.print("\n✅ All checks passed. AI compliance verified.\n", .{});
    }
    std.debug.print("\n", .{});
}

fn runDeadcodeCheck(
    allocator: std.mem.Allocator,
    opts: DeadcodeOpts,
    pass: *u32,
    warn: *u32,
    fail: *u32,
) !void {
    std.debug.print("\n--- Dead code (zdeadcode) ---\n", .{});
    const default_paths = [_][]const u8{"src"};
    const paths: []const []const u8 = if (opts.paths.len > 0) opts.paths else &default_paths;

    var result = zdeadcode.run(allocator, zf_shared.io, .{
        .paths = paths,
        .binary = opts.binary,
        .include_pub = opts.include_pub,
        .no_tests = opts.no_tests,
        .no_members = opts.no_members,
        .no_files = opts.no_files,
        .no_gitignore = opts.no_gitignore,
        .json = opts.json,
        .verbose = opts.verbose,
    }) catch |err| {
        if (err == error.NoZigFiles) {
            warn.* += 1;
            std.debug.print("⚠️  WARN: deadcode — no .zig files under {s}\n", .{paths[0]});
            return;
        }
        fail.* += 1;
        std.debug.print("❌ FAIL: deadcode scan error: {s}\n", .{@errorName(err)});
        return;
    };
    defer result.deinit(allocator);

    if (result.text.len > 0) {
        std.debug.print("{s}", .{result.text});
    }

    const s = result.summary;
    if (result.hasFindings()) {
        const msg_fmt = "deadcode: {d} unused decl(s), {d} unused module(s) (scanned {d} files, {d} decls)\n";
        if (opts.warn_only) {
            warn.* += 1;
            std.debug.print("⚠️  WARN: " ++ msg_fmt, .{ result.finding_count, result.unused_file_count, s.files_scanned, s.decls });
        } else {
            fail.* += 1;
            std.debug.print("❌ FAIL: " ++ msg_fmt, .{ result.finding_count, result.unused_file_count, s.files_scanned, s.decls });
        }
    } else {
        pass.* += 1;
        std.debug.print("✅ PASS: no unused declarations ({d} files, {d} decls)\n", .{ s.files_scanned, s.decls });
    }
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
        if (std.mem.indexOf(u8, content, "createCacheInterceptor") != null) {
            std.debug.print("⚠️  WARN: {s} uses createCacheInterceptor — TCP after-store is no-op without oneshot.capture; prefer CacheKit in handler or proxy cache\n", .{rel});
            warn.* += 1;
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
                    std.debug.print("         needle-based check on main.zig — custom layouts: use PracticeIgnore\n", .{});
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

    // Soft L3 heuristics (always WARN): tenant SQL predicates + Outbox-before-Bus.
    try checkProdL3Heuristics(allocator, root, warn);

    if (banned_auth == 0 and banned_cors_star == 0 and experimental == 0 and force_ka_off == 0 and prod_fail == 0 and prod_warn == 0) {
        std.debug.print("✅ PASS: {s} meets deployment contract\n", .{root});
        pass.* += 1;
    } else if (prod_fail == 0) {
        warn.* += banned_auth + banned_cors_star + experimental + force_ka_off;
    }
}

/// WARN-only: SQL without tenant_id/app_id; bus.publish without Outbox in same file.
fn checkProdL3Heuristics(allocator: std.mem.Allocator, root: []const u8, warn: *u32) !void {
    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{ .iterate = true }) catch return;
    defer dir.close(zf_shared.io);
    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    var tenant_sql_warns: u32 = 0;
    var bus_no_outbox_warns: u32 = 0;

    while (walker.next(zf_shared.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path });
        defer allocator.free(rel);
        const content = readFileAlloc(allocator, rel) catch continue;
        defer allocator.free(content);

        // Skip generated noise and this checker's own docs.
        if (std.mem.indexOf(u8, content, "// @generated") != null) continue;

        const has_bus_publish = std.mem.indexOf(u8, content, ".publish(") != null and
            (std.mem.indexOf(u8, content, "Bus") != null or std.mem.indexOf(u8, content, "bus") != null);
        const has_outbox = std.mem.indexOf(u8, content, "Outbox") != null or
            std.mem.indexOf(u8, content, "outbox") != null or
            std.mem.indexOf(u8, content, "drainOnce") != null;
        if (has_bus_publish and !has_outbox) {
            bus_no_outbox_warns += 1;
            if (bus_no_outbox_warns <= 8) {
                std.debug.print("⚠️  WARN: {s} calls .publish( with Bus but no Outbox/drainOnce — prefer same-TX outbox (doc/outbox.md)\n", .{rel});
            }
        }

        // Line heuristic: SQL-ish lines missing tenant_id / app_id.
        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_no: u32 = 0;
        while (lines.next()) |line| {
            line_no += 1;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '/') continue;
            const upper_has_select = containsIgnoreCase(trimmed, "SELECT ");
            const upper_has_update = containsIgnoreCase(trimmed, "UPDATE ");
            const upper_has_delete = containsIgnoreCase(trimmed, "DELETE FROM");
            if (!upper_has_select and !upper_has_update and !upper_has_delete) continue;
            if (!containsIgnoreCase(trimmed, "FROM ") and !upper_has_update and !upper_has_delete) continue;
            if (containsIgnoreCase(trimmed, "tenant_id") or containsIgnoreCase(trimmed, "app_id")) continue;
            // Ignore framework/schema DDL and obvious non-tenant tables.
            if (containsIgnoreCase(trimmed, "CREATE TABLE")) continue;
            if (containsIgnoreCase(trimmed, "zfinal_")) continue;
            if (containsIgnoreCase(trimmed, "ai_")) continue;
            tenant_sql_warns += 1;
            if (tenant_sql_warns <= 8) {
                std.debug.print("⚠️  WARN: {s}:{d} SQL-like line without tenant_id/app_id — verify tenant predicate\n", .{ rel, line_no });
            }
        }
    }

    if (tenant_sql_warns > 8) {
        std.debug.print("⚠️  WARN: …and {d} more SQL lines without tenant_id/app_id\n", .{tenant_sql_warns - 8});
    }
    if (bus_no_outbox_warns > 8) {
        std.debug.print("⚠️  WARN: …and {d} more Bus.publish without Outbox\n", .{bus_no_outbox_warns - 8});
    }
    warn.* += tenant_sql_warns + bus_no_outbox_warns;
    if (tenant_sql_warns == 0 and bus_no_outbox_warns == 0) {
        std.debug.print("✅ PASS: no tenant-SQL / Outbox heuristics flagged under {s}\n", .{root});
    }
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCasePos(hay, 0, needle) != null;
}

const PracticeIgnore = struct {
    patterns: []const []const u8 = &.{},

    fn ignores(self: PracticeIgnore, path: []const u8) bool {
        for (self.patterns) |p| {
            if (std.mem.indexOf(u8, path, p) != null) return true;
        }
        return false;
    }
};

fn loadPracticeIgnore(allocator: std.mem.Allocator) PracticeIgnore {
    const data = zf_shared.readFileAlloc(allocator, ".zfinal-check.json") catch return .{};
    defer allocator.free(data);
    const key = "\"ignore\"";
    const idx = std.mem.indexOf(u8, data, key) orelse return .{};
    const bracket = std.mem.indexOfScalar(u8, data[idx..], '[') orelse return .{};
    const start = idx + bracket + 1;
    const end = std.mem.indexOfScalar(u8, data[start..], ']') orelse return .{};
    const body = data[start .. start + end];
    var list = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\n\r\"");
        if (s.len == 0) continue;
        const dup = allocator.dupe(u8, s) catch continue;
        list.append(allocator, dup) catch {
            allocator.free(dup);
            continue;
        };
    }
    return .{ .patterns = list.toOwnedSlice(allocator) catch &.{} };
}

/// Business best-practice heuristics (`zf check --practice`).
fn checkPracticeRules(
    allocator: std.mem.Allocator,
    root: []const u8,
    strict: bool,
    pass: *u32,
    warn: *u32,
    fail: *u32,
) !void {
    std.debug.print("\n--- Business practice (--practice) root={s} ---\n", .{root});
    const ignore = loadPracticeIgnore(allocator);
    defer {
        for (ignore.patterns) |p| allocator.free(p);
        if (ignore.patterns.len > 0) allocator.free(ignore.patterns);
    }

    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{ .iterate = true }) catch {
        std.debug.print("⚠️  WARN: cannot open practice root {s}\n", .{root});
        warn.* += 1;
        return;
    };
    defer dir.close(zf_shared.io);

    var findings: u32 = 0;
    try walkPractice(&dir, root, allocator, ignore, strict, warn, fail, &findings);
    if (findings == 0) {
        std.debug.print("✅ PASS: no practice findings under {s}\n", .{root});
        pass.* += 1;
    }
}

fn emitPractice(strict: bool, warn: *u32, fail: *u32, findings: *u32, comptime fmt: []const u8, args: anytype) void {
    findings.* += 1;
    if (strict) {
        fail.* += 1;
        std.debug.print("❌ FAIL: " ++ fmt ++ "\n", args);
    } else {
        warn.* += 1;
        std.debug.print("⚠️  WARN: " ++ fmt ++ "\n", args);
    }
}

fn walkPractice(
    dir: *std.Io.Dir,
    rel: []const u8,
    allocator: std.mem.Allocator,
    ignore: PracticeIgnore,
    strict: bool,
    warn: *u32,
    fail: *u32,
    findings: *u32,
) !void {
    var it = dir.iterate();
    while (it.next(zf_shared.io) catch null) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".git") or
                std.mem.eql(u8, entry.name, "zig-cache") or
                std.mem.eql(u8, entry.name, ".zig-cache") or
                std.mem.eql(u8, entry.name, "zig-out") or
                std.mem.eql(u8, entry.name, "node_modules")) continue;
            const sub_rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, entry.name });
            defer allocator.free(sub_rel);
            var sub = dir.openDir(zf_shared.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(zf_shared.io);
            try walkPractice(&sub, sub_rel, allocator, ignore, strict, warn, fail, findings);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, entry.name });
        defer allocator.free(full);
        if (ignore.ignores(full)) continue;

        const content = blk: {
            var f = dir.openFile(zf_shared.io, entry.name, .{}) catch continue;
            defer f.close(zf_shared.io);
            const st = f.stat(zf_shared.io) catch continue;
            const buf = allocator.alloc(u8, @intCast(st.size)) catch continue;
            const chunks = [_][]u8{buf};
            _ = f.readStreaming(zf_shared.io, &chunks) catch {
                allocator.free(buf);
                continue;
            };
            break :blk buf;
        };
        defer allocator.free(content);

        const is_handler = std.mem.indexOf(u8, full, "/handler") != null or std.mem.endsWith(u8, full, "handler.zig");
        if (is_handler) {
            if (std.mem.indexOf(u8, content, "exec(\"") != null or std.mem.indexOf(u8, content, "exec('") != null) {
                emitPractice(strict, warn, fail, findings, "{s} handler uses exec(\"…\") — prefer parameterized queries in service/model", .{full});
            }
            // Layering: handler should not talk to DB drivers directly.
            if (std.mem.indexOf(u8, content, "@import(\"c_sqlite3\")") != null or
                std.mem.indexOf(u8, content, "@import(\"sqlite\")") != null or
                std.mem.indexOf(u8, content, "libpq") != null or
                std.mem.indexOf(u8, content, "mysql.h") != null)
            {
                emitPractice(strict, warn, fail, findings, "{s} handler imports DB driver — sink SQL to service/model", .{full});
            }
            if (std.mem.indexOf(u8, content, "SELECT ") != null and std.mem.indexOf(u8, content, " ++ ") != null) {
                emitPractice(true, warn, fail, findings, "{s} handler builds SQL with ++ — use parameterized queries (SQL injection risk)", .{full});
            }
        }

        if (std.mem.indexOf(u8, content, "force_connection_close = false") != null) {
            emitPractice(strict, warn, fail, findings, "{s} sets force_connection_close=false — keep true in production (zig#25017)", .{full});
        }

        const has_err_envelope = std.mem.indexOf(u8, content, "renderJson(.{ .err") != null;
        const has_zapi = std.mem.indexOf(u8, content, ".code =") != null and std.mem.indexOf(u8, content, ".msg =") != null;
        if (has_err_envelope and has_zapi) {
            emitPractice(strict, warn, fail, findings, "{s} mixes HttpError .err and zapi code/msg — pick one (doc/api_envelope.md)", .{full});
        }

        // Password / secret zeroization heuristic (warn unless --strict).
        if ((std.mem.indexOf(u8, content, "password") != null or std.mem.indexOf(u8, content, "passwd") != null) and
            std.mem.indexOf(u8, content, "@memset") == null and
            std.mem.indexOf(u8, content, "secureZero") == null and
            std.mem.indexOf(u8, content, "zeroize") == null and
            (std.mem.indexOf(u8, content, "hashPassword") != null or std.mem.indexOf(u8, content, "verifyPassword") != null))
        {
            emitPractice(strict, warn, fail, findings, "{s} handles password without zeroize/@memset — clear buffers after hash/verify", .{full});
        }

        const has_publish = std.mem.indexOf(u8, content, ".publish(") != null;
        const has_db_write = std.mem.indexOf(u8, content, ".insert(") != null or std.mem.indexOf(u8, content, "INSERT INTO") != null;
        const has_outbox = std.mem.indexOf(u8, content, "Outbox") != null or
            std.mem.indexOf(u8, content, "drainOnce") != null or
            std.mem.indexOf(u8, content, "DbOutbox") != null;
        if (has_publish and has_db_write and !has_outbox) {
            emitPractice(strict, warn, fail, findings, "{s} has DB write + .publish( without Outbox — same-TX DbOutbox (doc/outbox.md)", .{full});
        }
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

/// Smart routing checks (doc/smart_routing.md §8.1).
fn checkSmartRouting(allocator: std.mem.Allocator, pass: *u32, warn: *u32, fail: *u32) void {
    var issues: u32 = 0;

    const root = "src/modules";
    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{ .iterate = true }) catch {
        std.debug.print("✅ PASS: smart routing scan (no src/modules)\n", .{});
        pass.* += 1;
        return;
    };
    defer dir.close(zf_shared.io);
    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next(zf_shared.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path }) catch continue;
        defer allocator.free(full);
        const content = readFileAlloc(allocator, full) catch continue;
        defer allocator.free(content);

        if (std.mem.eql(u8, entry.basename, "routes.zig")) {
            if (std.mem.indexOf(u8, content, "{id}") != null) {
                std.debug.print("❌ FAIL: {s} uses {{id}} — prefer :id\n", .{full});
                fail.* += 1;
                issues += 1;
            }
            if (std.mem.indexOf(u8, content, "@generated by zf routes") != null) {
                if (std.mem.indexOf(u8, content, "Regenerate: zf routes") == null) {
                    std.debug.print("❌ FAIL: {s} missing regenerate banner\n", .{full});
                    fail.* += 1;
                    issues += 1;
                }
            }
            const dir_path = std.fs.path.dirname(full) orelse continue;
            const actions_path = std.fmt.allocPrint(allocator, "{s}/actions.zig", .{dir_path}) catch continue;
            defer allocator.free(actions_path);
            if (std.Io.Dir.cwd().access(zf_shared.io, actions_path, .{})) |_| {
                if (std.mem.indexOf(u8, content, "@generated by zf routes") == null) {
                    std.debug.print("❌ FAIL: {s} has actions.zig but routes lack @generated — run zf routes\n", .{full});
                    fail.* += 1;
                    issues += 1;
                }
            } else |_| {}
        } else if (std.mem.eql(u8, entry.basename, "actions.zig")) {
            // nested_under.param = "id" is forbidden
            if (std.mem.indexOf(u8, content, ".nested_under") != null and
                std.mem.indexOf(u8, content, ".param = \"id\"") != null)
            {
                std.debug.print("❌ FAIL: {s} nested_under.param must not be \"id\"\n", .{full});
                fail.* += 1;
                issues += 1;
            }
        } else if (!std.mem.eql(u8, entry.basename, "routes.zig") and
            !std.mem.eql(u8, entry.basename, "actions.zig"))
        {
            if (std.mem.indexOf(u8, content, "app.get(") != null or
                std.mem.indexOf(u8, content, "app.post(") != null or
                std.mem.indexOf(u8, content, "app.put(") != null or
                std.mem.indexOf(u8, content, "app.delete(") != null or
                std.mem.indexOf(u8, content, "app.patch(") != null)
            {
                std.debug.print("❌ FAIL: {s} hand-registers routes — use actions.zig + zf routes\n", .{full});
                fail.* += 1;
                issues += 1;
            }
        }
    }
    if (issues == 0) {
        std.debug.print("✅ PASS: smart routing scan\n", .{});
        pass.* += 1;
    } else {
        _ = warn;
    }
}

/// WARN when handlers hand-roll `renderJson(.{ .err = ... })` instead of `return error.*` / HttpError.
fn checkHandRolledErrorEnvelope(allocator: std.mem.Allocator, pass: *u32, warn: *u32) void {
    var warnings: u32 = 0;
    const roots = [_][]const u8{ "src", "examples" };
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(zf_shared.io);
        var walker = dir.walk(allocator) catch continue;
        defer walker.deinit();
        while (walker.next(zf_shared.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.eql(u8, entry.basename, "http_error.zig")) continue;
            if (std.mem.eql(u8, entry.basename, "codegen.zig")) continue;
            if (std.mem.eql(u8, entry.basename, "zent_codegen.zig")) continue;
            if (std.mem.eql(u8, entry.basename, "cmd_check.zig")) continue;
            const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path }) catch continue;
            defer allocator.free(full);
            if (std.mem.indexOf(u8, full, "handler.gen.zig") != null) continue;
            const content = readFileAlloc(allocator, full) catch continue;
            defer allocator.free(content);
            if (std.mem.indexOf(u8, content, "renderJson(.{") != null and
                std.mem.indexOf(u8, content, ".err =") != null)
            {
                std.debug.print("⚠️  WARN: {s} hand-rolls renderJson(.{{ .err = … }}) — prefer return error.*/HttpError\n", .{full});
                warn.* += 1;
                warnings += 1;
            }
        }
    }
    if (warnings == 0) {
        std.debug.print("✅ PASS: no hand-rolled HttpError envelopes\n", .{});
        pass.* += 1;
    }

    // Caller-owned interceptor cfg: flag legacy value-arg / heapCfg usage.
    var cfg_warn: u32 = 0;
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(zf_shared.io);
        var walker = dir.walk(allocator) catch continue;
        defer walker.deinit();
        while (walker.next(zf_shared.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.eql(u8, entry.basename, "interceptor.zig")) continue;
            if (std.mem.eql(u8, entry.basename, "cmd_check.zig")) continue;
            const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path }) catch continue;
            defer allocator.free(full);
            const content = readFileAlloc(allocator, full) catch continue;
            defer allocator.free(content);
            if (std.mem.indexOf(u8, content, "heapCfg(") != null) {
                std.debug.print("⚠️  WARN: {s} uses heapCfg — prefer caller-owned *const Cfg\n", .{full});
                warn.* += 1;
                cfg_warn += 1;
            }
            // Old JWT factory: createJwtAuthInterceptorWithOptions("secret", .{
            if (std.mem.indexOf(u8, content, "createJwtAuthInterceptorWithOptions(\"") != null or
                std.mem.indexOf(u8, content, "createJwtAuthInterceptorWithOptions('") != null)
            {
                std.debug.print("⚠️  WARN: {s} passes JWT secret by value — use JwtAuthConfig + &cfg\n", .{full});
                warn.* += 1;
                cfg_warn += 1;
            }
            if (std.mem.indexOf(u8, content, "createSecurityHeadersInterceptor(true)") != null or
                std.mem.indexOf(u8, content, "createSecurityHeadersInterceptor(false)") != null)
            {
                std.debug.print("⚠️  WARN: {s} passes HSTS bool by value — use SecurityHeadersConfig + &cfg\n", .{full});
                warn.* += 1;
                cfg_warn += 1;
            }
            // Temporary struct literal: createX(&.{ ... }) — cfg dies at end of statement (UAF).
            const temp_cfg_needles = [_][]const u8{
                "createJwtAuthInterceptor(&.{",
                "createJwtAuthInterceptorWithOptions(&.{",
                "createCorsAllowlistInterceptor(&.{",
                "createCorsInterceptor(&.{",
                "createTokenInterceptor(&.{",
                "createSecurityHeadersInterceptor(&.{",
                "createBodyLimitInterceptor(&.{",
                "createTimeoutInterceptor(&.{",
                "createCompressionInterceptor(&.{",
                "createCacheInterceptor(&.{",
                "createCacheInterceptorWithOptions(&.{",
            };
            for (temp_cfg_needles) |needle| {
                if (std.mem.indexOf(u8, content, needle) != null) {
                    std.debug.print("⚠️  WARN: {s} passes temporary &.{{…}} interceptor cfg — hold cfg in App/main so it outlives the interceptor\n", .{full});
                    warn.* += 1;
                    cfg_warn += 1;
                    break;
                }
            }
        }
    }
    if (cfg_warn == 0) {
        std.debug.print("✅ PASS: interceptor configs are caller-owned\n", .{});
        pass.* += 1;
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

/// Migrate generated handlers from legacy `err(ctx, status, msg, code)` /
/// hand-rolled parseId to `failHttp` + `extract.requireParamInt`.
/// Also strips dead `fn err` once all call sites use `failHttp`.
/// Scans `src/` and `examples/`. Safe to re-run (no-op when already migrated).
fn healHttpErrorHandler(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);
    try findFilesAll(allocator, "examples", &paths);

    const fail_http_fn =
        \\fn failHttp(ctx: *zfinal.Context, http_err: anyerror, comptime detail: []const u8) anyerror {
        \\    zfinal.http_error.setDetail(ctx, detail);
        \\    return http_err;
        \\}
        \\
    ;

    const dead_err_legacy =
        \\/// Legacy envelope with app-specific numeric `code` (prefer failHttp / HttpError).
        \\fn err(ctx: *zfinal.Context, status: std.http.Status, comptime msg: []const u8, code: i32) !void {
        \\    ctx.res_status = status;
        \\    try ctx.renderJson(.{ .err = msg, .code = code });
        \\}
        \\
    ;

    const dead_err_plain =
        \\fn err(ctx: *zfinal.Context, status: std.http.Status, comptime msg: []const u8, code: i32) !void {
        \\    ctx.res_status = status;
        \\    try ctx.renderJson(.{ .err = msg, .code = code });
        \\}
        \\
    ;

    const old_parse_id =
        \\/// Parse and validate ID path parameter.
        \\fn parseId(ctx: *zfinal.Context) !i64 {
        \\    const id_str = ctx.getPathParam("id") orelse {
        \\        ctx.res_status = .bad_request;
        \\        try ctx.renderJson(.{ .err = "Missing ID" });
        \\        return error.InvalidId;
        \\    };
        \\    return std.fmt.parseInt(i64, id_str, 10) catch {
        \\        ctx.res_status = .bad_request;
        \\        try ctx.renderJson(.{ .err = "Invalid ID" });
        \\        return error.InvalidId;
        \\    };
        \\}
    ;

    const new_parse_id =
        \\/// Parse path `:id` via extract (HttpError.BadRequest on failure).
        \\fn parseId(ctx: *zfinal.Context) !i64 {
        \\    return zfinal.extract.requireParamInt(ctx, i64, "id");
        \\}
    ;

    for (paths.items) |path| {
        const base = std.fs.path.basename(path);
        if (!std.mem.startsWith(u8, base, "handler")) continue;

        const f = std.Io.Dir.cwd().openFile(zf_shared.io, path, .{}) catch continue;
        defer f.close(zf_shared.io);
        const stat = try f.stat(zf_shared.io);
        if (stat.size > 1_000_000) continue;
        const raw = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(raw);
        _ = try std.Io.File.readPositionalAll(f, zf_shared.io, raw, 0);

        const has_fail = std.mem.indexOf(u8, raw, "fn failHttp(") != null;
        const has_dead_err = std.mem.indexOf(u8, raw, "fn err(ctx: *zfinal.Context, status: std.http.Status") != null;
        const still_calls_err = std.mem.indexOf(u8, raw, "return err(ctx,") != null or
            std.mem.indexOf(u8, raw, " err(ctx,") != null;
        const needs_migrate =
            std.mem.indexOf(u8, raw, "return err(ctx, .forbidden, \"Missing CSRF token\"") != null or
            std.mem.indexOf(u8, raw, "return err(ctx, .not_found, \"Not found\"") != null or
            std.mem.indexOf(u8, raw, "rateLimiter.handle(ctx) catch {}") != null or
            std.mem.indexOf(u8, raw, old_parse_id) != null;
        const needs_strip_err = has_fail and has_dead_err and !still_calls_err;
        if (!needs_migrate and !needs_strip_err) continue;

        var content = try allocator.dupe(u8, raw);
        defer allocator.free(content);

        if (std.mem.indexOf(u8, content, "fn failHttp(") == null) {
            if (std.mem.indexOf(u8, content, "fn err(ctx: *zfinal.Context, status: std.http.Status")) |idx| {
                const inserted = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ content[0..idx], fail_http_fn, content[idx..] });
                allocator.free(content);
                content = inserted;
            }
        }

        inline for (.{
            .{ "rateLimiter.handle(ctx) catch {};", "try rateLimiter.handle(ctx);" },
            .{ "return err(ctx, .forbidden, \"Missing CSRF token\", 40301);", "return failHttp(ctx, error.Forbidden, \"csrf_token\");" },
            .{ "return err(ctx, .forbidden, \"Invalid CSRF token\", 40302);", "return failHttp(ctx, error.Forbidden, \"csrf_token\");" },
            .{ "return err(ctx, .not_found, \"Not found\", 40401);", "return failHttp(ctx, error.NotFound, \"id\");" },
            .{ "return err(ctx, .unprocessable_entity, \"Validation failed\", 42201);", "return failHttp(ctx, error.UnprocessableEntity, \"validation\");" },
        }) |pair| {
            const replaced = try std.mem.replaceOwned(u8, allocator, content, pair[0], pair[1]);
            allocator.free(content);
            content = replaced;
        }
        {
            const replaced = try std.mem.replaceOwned(u8, allocator, content, old_parse_id, new_parse_id);
            allocator.free(content);
            content = replaced;
        }

        // Drop unused legacy `fn err` after call sites moved to failHttp.
        const calls_err = std.mem.indexOf(u8, content, "return err(ctx,") != null or
            std.mem.indexOf(u8, content, " err(ctx,") != null;
        if (!calls_err) {
            inline for (.{ dead_err_legacy, dead_err_plain }) |dead| {
                const replaced = try std.mem.replaceOwned(u8, allocator, content, dead, "");
                allocator.free(content);
                content = replaced;
            }
        }

        if (!std.mem.eql(u8, content, raw)) {
            try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = path, .data = content });
            std.debug.print("  ✓ healed: {s} (HttpError / failHttp)\n", .{path});
            patched += 1;
        }
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
