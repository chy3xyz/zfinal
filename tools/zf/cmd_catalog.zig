//! Single source of truth for `zf` command names, aliases, and help lines.
const std = @import("std");

pub const Command = enum {
    new,
    generate,
    api,
    migrate,
    test_gen,
    docker,
    deploy,
    build_cmd,
    serve,
    test_run,
    version,
    help,
    crud,
    crud_sql,
    crud_zent,
    crud_dsn,
    check,
    upgrade,
    life,
    admin,
    seed,
    fixture,
    bench,
    ai,
    openapi,
    routes,
    gate,
    release_check,
    market,
    doctor,
};

pub const Entry = struct {
    cmd: Command,
    /// Primary name shown in help / used for discovery.
    name: []const u8,
    /// Optional short alias (e.g. "g").
    alias: ?[]const u8 = null,
    /// One-line help (may be multi-line with leading spaces for continuation).
    help: []const u8,
};

/// Canonical command table — `parseCommand` and `printHelp` both use this.
pub const entries = [_]Entry{
    .{ .cmd = .new, .name = "new", .help = "new <name> [--clean] [--json]  Create a new ZFinal project (HTMX template)" },
    .{ .cmd = .generate, .name = "generate", .alias = "g", .help = "generate, g <type> <name>  Generate handler|model|middleware|service|task|port" },
    .{ .cmd = .api, .name = "api", .help = "api <name>              Generate API handler (JSON output)" },
    .{ .cmd = .migrate, .name = "migrate", .help = "migrate <action> [name] Manage database migrations" },
    .{ .cmd = .test_gen, .name = "test:gen", .help = "test:gen <name>         Generate test file stub" },
    .{ .cmd = .crud, .name = "crud", .help = "crud <db> <table>       Generate full CRUD from SQLite DB schema" },
    .{ .cmd = .crud_sql, .name = "crud:sql", .help = "crud:sql <file> [name]  Generate from .sql file (DB/Model data layer)" },
    .{ .cmd = .crud_zent, .name = "crud:zent", .help = "crud:zent <file>        Generate from .zent/.json (zent primary data layer)" },
    .{ .cmd = .crud_dsn, .name = "crud:dsn", .help = "crud:dsn <url>          Generate CRUD from live PG/MySQL DSN" },
    .{ .cmd = .admin, .name = "admin", .help = "admin <file>            Generate vben-style admin HTML (htmx + alpine + tailwind)" },
    .{ .cmd = .check, .name = "check", .help = "check [--prod] [--practice] [--root R] [--heal] [--deadcode]\n                            AI boundary + production + business-practice audit" },
    .{ .cmd = .routes, .name = "routes", .help = "routes [--json] [--check] [--root DIR]\n                            Generate routes.zig from modules/**/actions.zig" },
    .{ .cmd = .openapi, .name = "openapi", .help = "openapi [--out <file>]  Generate minimal OpenAPI 3.0.3 from project routes" },
    .{ .cmd = .gate, .name = "gate", .help = "gate [--quick|--full|--release] [--strict]  Productized quality gate" },
    .{ .cmd = .release_check, .name = "release-check", .help = "release-check [--no-strict]  Pre-tag gate (default --strict)" },
    .{ .cmd = .market, .name = "market", .help = "market <list|search|info>  Local module marketplace catalog" },
    .{ .cmd = .doctor, .name = "doctor", .help = "doctor [--json]         Diagnose PATH/version/project wiring for zf" },
    .{ .cmd = .seed, .name = "seed", .help = "seed <action>           Database seeding companion to migrate" },
    .{ .cmd = .fixture, .name = "fixture", .help = "fixture …              Test fixture helpers" },
    .{ .cmd = .bench, .name = "bench", .help = "bench <url> […]        HTTP micro-bench against a running server" },
    .{ .cmd = .ai, .name = "ai", .help = "ai <prompt…>           Ask an LLM about this project (needs API key)" },
    .{ .cmd = .upgrade, .name = "upgrade", .help = "upgrade                 Upgrade zfinal dependency to latest release" },
    .{ .cmd = .life, .name = "life", .help = "life [status|…]         Project evolution / .life helpers" },
    .{ .cmd = .docker, .name = "docker", .help = "docker                  Generate Dockerfile" },
    .{ .cmd = .deploy, .name = "deploy", .help = "deploy                  Print deploy hints" },
    .{ .cmd = .build_cmd, .name = "build", .alias = "b", .help = "build, b                Build release binary (prints zig build hint)" },
    .{ .cmd = .serve, .name = "serve", .alias = "s", .help = "serve, s                Start development server (prints zig build run)" },
    .{ .cmd = .test_run, .name = "test", .alias = "t", .help = "test, t                 Run tests (prints zig build test)" },
    .{ .cmd = .version, .name = "version", .alias = "v", .help = "version, v              Show version information" },
    .{ .cmd = .help, .name = "help", .alias = "h", .help = "help, h                 Show this help message" },
};

/// Commands that must appear in `zf help` (quality gate / doctor).
pub const required_help_names = [_][]const u8{
    "routes",
    "openapi",
    "gate",
    "market",
    "release-check",
    "crud:sql",
    "check",
    "doctor",
};

pub fn parseCommand(cmd: []const u8) ?Command {
    for (entries) |e| {
        if (std.mem.eql(u8, cmd, e.name)) return e.cmd;
        if (e.alias) |a| {
            if (std.mem.eql(u8, cmd, a)) return e.cmd;
        }
    }
    return null;
}

pub fn printHelp(exe_name: []const u8) void {
    std.debug.print("\n", .{});
    std.debug.print("ZFinal CLI (zf) - Zig Web Framework Tool\n", .{});
    std.debug.print("=========================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Usage: {s} <command> [options]\n", .{exe_name});
    std.debug.print("\n", .{});
    std.debug.print("Commands:\n", .{});
    for (entries) |e| {
        std.debug.print("  {s}\n", .{e.help});
    }
    std.debug.print("\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  {s} new myapp\n", .{exe_name});
    std.debug.print("  {s} crud:sql schema.sql --json\n", .{exe_name});
    std.debug.print("  {s} crud:zent schema.zent --json\n", .{exe_name});
    std.debug.print("  {s} routes --json && {s} check --prod --root .\n", .{ exe_name, exe_name });
    std.debug.print("  {s} doctor --json\n", .{exe_name});
    std.debug.print("  {s} gate --quick\n", .{exe_name});
    std.debug.print("\n", .{});
    std.debug.print("Tip: always prefer ./zig-out/bin/zf after `zig build install-zf`\n", .{});
    std.debug.print("     (stale PATH binaries may lack routes/gate/doctor).\n", .{});
    std.debug.print("\n", .{});
}

/// Suggest closest command name (edit distance ≤ 3). Returns null if none.
pub fn suggestCommand(unknown: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 4;
    for (entries) |e| {
        const d1 = editDistance(unknown, e.name);
        if (d1 < best_dist) {
            best_dist = d1;
            best = e.name;
        }
        if (e.alias) |a| {
            const d2 = editDistance(unknown, a);
            if (d2 < best_dist) {
                best_dist = d2;
                best = a;
            }
        }
    }
    return if (best_dist <= 3) best else null;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    // Bounded Levenshtein for short CLI tokens (stack DP).
    if (a.len > 32 or b.len > 32) return 99;
    var prev: [33]usize = undefined;
    var cur: [33]usize = undefined;
    var j: usize = 0;
    while (j <= b.len) : (j += 1) prev[j] = j;
    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        cur[0] = i;
        j = 1;
        while (j <= b.len) : (j += 1) {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            const del = prev[j] + 1;
            const ins = cur[j - 1] + 1;
            const sub = prev[j - 1] + cost;
            cur[j] = @min(del, @min(ins, sub));
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

test "cmd_catalog parse aliases" {
    try std.testing.expect(parseCommand("g") == .generate);
    try std.testing.expect(parseCommand("routes") == .routes);
    try std.testing.expect(parseCommand("doctor") == .doctor);
    try std.testing.expect(parseCommand("release-check") == .release_check);
    try std.testing.expect(parseCommand("nope") == null);
}

test "cmd_catalog suggest" {
    try std.testing.expectEqualStrings("routes", suggestCommand("route").?);
    try std.testing.expect(suggestCommand("zzzzzzzz") == null);
}

test "cmd_catalog required help names parse" {
    for (required_help_names) |name| {
        try std.testing.expect(parseCommand(name) != null);
    }
}
