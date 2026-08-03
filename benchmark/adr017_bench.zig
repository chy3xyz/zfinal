//! ADR-017 feature micro-benchmark.
//!
//! Quantifies the runtime cost of the declarative list-query / DTO layer:
//!   `Model.Query` (build + paginate), `bindStruct` (declarative DTO bind),
//!   `bindJsonInto` (arena JSON parse), `validateUnique` (per-@unique extra
//!   SELECT), and `toView` (struct projection).
//! Run via: `zig build run-adr017-bench` (ReleaseFast).
//!
//! Methodology: in-memory SQLite, 5_000 posts (alternating pub/draft),
//! warmed once, then N timed iterations per path. All times exclude the
//! warmup. As with db_decode, in-process SQLite has no wire cost, so these
//! are CPU/allocation costs only — PG/MySQL wire savings are not measured.

const std = @import("std");
const zfinal = @import("zfinal");

const DBConfig = zfinal.DBConfig;
const DB = zfinal.DB;
const SqlParam = zfinal.SqlParam;

const ROWS: usize = 5_000;
const ITERS: usize = 200;

const Post = struct {
    id: i64,
    title: []const u8,
    status: []const u8,
    views: i64,
};
const PostModel = zfinal.Model(Post, "posts");

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
}

fn setupDb(allocator: std.mem.Allocator) !*DB {
    var db = try DB.init(allocator, DBConfig.sqliteMemory());
    try db.exec("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, status TEXT NOT NULL, views INTEGER NOT NULL)");
    var i: usize = 0;
    while (i < ROWS) : (i += 1) {
        var buf: [64]u8 = undefined;
        const title = try std.fmt.bufPrint(&buf, "post number {d} with some words", .{i});
        _ = try db.execParams(
            "INSERT INTO posts (title, status, views) VALUES (?, ?, ?)",
            &.{
                SqlParam{ .text = title },
                SqlParam{ .text = if (i % 2 == 0) "pub" else "draft" },
                SqlParam{ .int = @intCast(i * 7 % 1000) },
            },
        );
    }
    return db;
}

fn benchQueryPaginate(allocator: std.mem.Allocator, db: *DB) !void {
    // warmup
    {
        var q = PostModel.Query.init(db, allocator);
        defer q.deinit();
        try q.textEq("status", "pub");
        var page = try q.paginate(1, 20, allocator);
        defer {
            for (page.list) |*it| it.deinit(allocator);
            page.deinit();
        }
    }
    const start = nowNs();
    var seen: usize = 0;
    var it: usize = 0;
    while (it < ITERS) : (it += 1) {
        var q = PostModel.Query.init(db, allocator);
        defer q.deinit();
        try q.textEq("status", "pub");
        try q.orderBy("views", .desc);
        var page = try q.paginate(1, 20, allocator);
        seen += page.list.len;
        for (page.list) |*row| row.deinit(allocator);
        page.deinit();
    }
    const end = nowNs();
    const ns_op = (end - start) / ITERS;
    std.debug.print("Query.paginate (eq+orderBy, 2500 rows)  {d:>8} ns/op  ({d} iters, {d} rows seen)\n", .{ ns_op, ITERS, seen });
}

fn benchModelPaginate(allocator: std.mem.Allocator, db: *DB) !void {
    {
        const items = try PostModel.paginate(db, 1, 20, allocator);
        defer {
            for (items) |*it| it.deinit(allocator);
            allocator.free(items);
        }
    }
    const start = nowNs();
    var seen: usize = 0;
    var it: usize = 0;
    while (it < ITERS) : (it += 1) {
        const items = try PostModel.paginate(db, 1, 20, allocator);
        seen += items.len;
        for (items) |*row| row.deinit(allocator);
        allocator.free(items);
    }
    const end = nowNs();
    std.debug.print("Model.paginate (baseline, no filter)    {d:>8} ns/op  ({d} iters, {d} rows seen)\n", .{ (end - start) / ITERS, ITERS, seen });
}

fn benchQueryPaginateNoFilter(allocator: std.mem.Allocator, db: *DB) !void {
    {
        var q = PostModel.Query.init(db, allocator);
        defer q.deinit();
        var page = try q.paginate(1, 20, allocator);
        defer {
            for (page.list) |*it| it.deinit(allocator);
            page.deinit();
        }
    }
    const start = nowNs();
    var seen: usize = 0;
    var it: usize = 0;
    while (it < ITERS) : (it += 1) {
        var q = PostModel.Query.init(db, allocator);
        defer q.deinit();
        var page = try q.paginate(1, 20, allocator);
        seen += page.list.len;
        for (page.list) |*row| row.deinit(allocator);
        page.deinit();
    }
    const end = nowNs();
    std.debug.print("Query.paginate (no filter, builder only) {d:>8} ns/op  ({d} iters, {d} rows seen)\n", .{ (end - start) / ITERS, ITERS, seen });
}

fn benchQueryListLike(allocator: std.mem.Allocator, db: *DB) !void {
    {
        var q = PostModel.Query.init(db, allocator);
        defer q.deinit();
        try q.likeAll(&.{ "title", "status" }, "pub");
        const items = try q.list(allocator);
        defer {
            for (items) |*it| it.deinit(allocator);
            allocator.free(items);
        }
    }
    const start = nowNs();
    var seen: usize = 0;
    var it: usize = 0;
    while (it < ITERS) : (it += 1) {
        var q = PostModel.Query.init(db, allocator);
        defer q.deinit();
        try q.likeAll(&.{ "title", "status" }, "pub");
        const items = try q.list(allocator);
        seen += items.len;
        for (items) |*row| row.deinit(allocator);
        allocator.free(items);
    }
    const end = nowNs();
    std.debug.print("Query.list (likeAll OR 2 cols)          {d:>8} ns/op  ({d} iters, {d} rows seen)\n", .{ (end - start) / ITERS, ITERS, seen });
}

/// Pattern-level replica of `Context.bindStruct` (comptime field iteration +
/// parseBound). Context itself is not linkable standalone here.
fn parseFilter(comptime FT: type, r: []const u8) FT {
    const is_opt = @typeInfo(FT) == .optional;
    const T = if (is_opt) @typeInfo(FT).optional.child else FT;
    return switch (@typeInfo(T)) {
        .int => if (is_opt)
            @as(FT, std.fmt.parseInt(T, r, 10) catch null)
        else
            @as(FT, std.fmt.parseInt(T, r, 10) catch 0),
        .bool => if (is_opt)
            @as(FT, std.mem.eql(u8, r, "1"))
        else
            @as(FT, std.mem.eql(u8, r, "1")),
        .@"enum" => if (is_opt)
            @as(FT, std.meta.stringToEnum(T, r))
        else
            @as(FT, std.meta.stringToEnum(T, r) orelse @enumFromInt(0)),
        .pointer => if (is_opt) @as(FT, r) else @as(FT, r),
        else => @compileError("unsupported"),
    };
}

fn benchBindStruct() !void {
    const Filters = struct {
        status: ?[]const u8 = null,
        views: ?i64 = null,
        active: ?bool = null,
        q: ?[]const u8 = null,
        sort: ?enum { asc, desc } = null,
        limit: i64 = 20,
    };
    const get = struct {
        fn get(name: []const u8) ?[]const u8 {
            _ = name;
            return "42";
        }
    }.get;

    var f: Filters = .{};
    const start = nowNs();
    var it: usize = 0;
    while (it < 1_000_000) : (it += 1) {
        f = .{};
        inline for (@typeInfo(Filters).@"struct".field_names, @typeInfo(Filters).@"struct".field_types) |fname, FT| {
            const raw = get(fname);
            if (raw) |r| @field(f, fname) = parseFilter(FT, r);
        }
    }
    const end = nowNs();
    std.debug.print("bindStruct (5 fields, comptime loop)    {d:>8} ns/op  (1,000,000 iters)\n", .{ (end - start) / 1_000_000 });
}

/// Pattern-level replica of `bindJsonInto` (arena JSON parse).
fn benchBindJson(allocator: std.mem.Allocator) !void {
    const Input = struct {
        title: []const u8 = "",
        status: []const u8 = "",
        views: i64 = 0,
        active: bool = false,
        q: []const u8 = "",
    };
    const body = "{\"title\":\"hello\",\"status\":\"pub\",\"views\":42,\"active\":true,\"q\":\"search term\"}";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var dto: Input = .{};
    {
        const parsed = std.json.parseFromSlice(Input, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
        parsed.deinit();
        dto = parsed.value;
    }
    const start = nowNs();
    var it: usize = 0;
    while (it < 100_000) : (it += 1) {
        const parsed = std.json.parseFromSlice(Input, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        parsed.deinit();
        dto = parsed.value;
    }
    const end = nowNs();
    std.debug.print("bindJsonInto (5-field JSON, arena)      {d:>8} ns/op  (100,000 iters)\n", .{ (end - start) / 100_000 });
}

fn benchValidateUnique(allocator: std.mem.Allocator, db: *DB) !void {
    {
        const existing = try PostModel.findWhere(db, "status = ?", &.{ SqlParam{ .text = "nope" } }, allocator);
        defer {
            for (existing) |*it| it.deinit(allocator);
            allocator.free(existing);
        }
    }
    const start = nowNs();
    var it: usize = 0;
    var hits: usize = 0;
    while (it < ITERS) : (it += 1) {
        // @unique check: findWhere + deinit (0 rows matched → no per-row work)
        const existing = try PostModel.findWhere(db, "status = ?", &.{ SqlParam{ .text = "nope" } }, allocator);
        defer {
            for (existing) |*row| row.deinit(allocator);
            allocator.free(existing);
        }
        hits += existing.len;
    }
    const end = nowNs();
    std.debug.print("validateUnique (0-hit SELECT + deinit)  {d:>8} ns/op  ({d} iters)\n", .{ (end - start) / ITERS, ITERS });
}

fn benchToView() !void {
    const View = struct {
        id: i64,
        title: []const u8,
        status: []const u8,
    };
    const instance = struct { data: Post };
    const v0 = instance{ .data = .{ .id = 1, .title = "t", .status = "pub", .views = 3 } };
    var sink: View = undefined;
    const start = nowNs();
    var it: usize = 0;
    while (it < 1_000_000) : (it += 1) {
        sink = .{ .id = v0.data.id, .title = v0.data.title, .status = v0.data.status };
    }
    const end = nowNs();
    std.debug.print("toView (3-field borrow copy)            {d:>8} ns/op  (1,000,000 iters)\n", .{ (end - start) / 1_000_000 });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("=== ADR-017 runtime cost (ReleaseFast, in-memory SQLite) ===\n", .{});
    var db = try setupDb(allocator);
    defer db.destroy();

    try benchModelPaginate(allocator, db);
    try benchQueryPaginateNoFilter(allocator, db);
    try benchQueryPaginate(allocator, db);
    try benchQueryListLike(allocator, db);
    try benchValidateUnique(allocator, db);
    try benchBindStruct();
    try benchBindJson(allocator);
    try benchToView();
}
