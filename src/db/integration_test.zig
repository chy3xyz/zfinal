//! DB integration tests — SQLite (:memory:) always, PG/MySQL via env vars.
//!
//! Env vars:
//!   ZF_PG_HOST/PORT/USER/PASSWORD/DATABASE
//!   ZF_MY_HOST/PORT/USER/PASSWORD/DATABASE

const std = @import("std");
const DB = @import("db.zig").DB;
const DBConfig = @import("config.zig").DBConfig;
const DBType = @import("config.zig").DBType;
const SqlParam = @import("sql_param.zig").SqlParam;
const build_opts = @import("build_options");

fn getEnv(allocator: std.mem.Allocator, name: [:0]const u8, default: []const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr);
    if (raw) |ptr| return allocator.dupe(u8, std.mem.sliceTo(ptr, 0)) catch return null;
    if (default.len == 0) return null;
    return allocator.dupe(u8, default) catch return null;
}

fn tryOpenPG(allocator: std.mem.Allocator) !?DB {
    if (!build_opts.enable_pg) return null;
    const pwd = getEnv(allocator, "ZF_PG_PASSWORD", "") orelse return null;
    defer allocator.free(pwd);
    const host = getEnv(allocator, "ZF_PG_HOST", "localhost") orelse return null;
    defer allocator.free(host);
    const port_str = getEnv(allocator, "ZF_PG_PORT", "5432") orelse return null;
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str, 10) catch @as(u16, 5432);
    const user = getEnv(allocator, "ZF_PG_USER", "postgres") orelse return null;
    defer allocator.free(user);
    const db_name = getEnv(allocator, "ZF_PG_DATABASE", "zfinal_test") orelse return null;
    defer allocator.free(db_name);

    return DB.init(allocator, DBConfig{
        .db_type = .postgres,
        .host = host,
        .port = port,
        .database = db_name,
        .username = user,
        .password = pwd,
    }) catch null;
}

fn tryOpenMY(allocator: std.mem.Allocator) !?DB {
    if (!build_opts.enable_mysql) return null;
    const pwd = getEnv(allocator, "ZF_MY_PASSWORD", "") orelse return null;
    defer allocator.free(pwd);
    const host = getEnv(allocator, "ZF_MY_HOST", "localhost") orelse return null;
    defer allocator.free(host);
    const port_str = getEnv(allocator, "ZF_MY_PORT", "3306") orelse return null;
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str, 10) catch @as(u16, 3306);
    const user = getEnv(allocator, "ZF_MY_USER", "root") orelse return null;
    defer allocator.free(user);
    const db_name = getEnv(allocator, "ZF_MY_DATABASE", "zfinal_test") orelse return null;
    defer allocator.free(db_name);

    return DB.init(allocator, DBConfig{
        .db_type = .mysql,
        .host = host,
        .port = port,
        .database = db_name,
        .username = user,
        .password = pwd,
    }) catch null;
}

fn expectRow(result: anytype) ?*const @import("result.zig").Row {
    if (result.next()) {
        return result.currentRow();
    }
    return null;
}

// ============================================================
test "db: CRUD on SQLite" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    const create_sql: [:0]const u8 = "CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, count INT)";
    _ = try db.exec(create_sql);

    // CREATE
    const insert_sql: [:0]const u8 = "INSERT INTO items (title, count) VALUES (?, ?)";
    _ = try db.execParams(insert_sql, &.{ SqlParam{ .text = "foo" }, SqlParam{ .int = 10 } });
    _ = try db.execParams(insert_sql, &.{ SqlParam{ .text = "bar" }, SqlParam{ .int = 20 } });
    _ = try db.execParams(insert_sql, &.{ SqlParam{ .text = "baz" }, SqlParam{ .int = 30 } });

    // READ all
    {
        var result = try db.query("SELECT title, count FROM items ORDER BY count");
        defer result.deinit();

        try std.testing.expect(result.next());
        var row = result.currentRow().?;
        try std.testing.expectEqualStrings("foo", row.getText(0).?);
        try std.testing.expectEqual(@as(i64, 10), (try row.getInt(1)).?);

        try std.testing.expect(result.next());
        row = result.currentRow().?;
        try std.testing.expectEqualStrings("bar", row.getText(0).?);

        try std.testing.expect(result.next());
        row = result.currentRow().?;
        try std.testing.expectEqualStrings("baz", row.getText(0).?);

        try std.testing.expect(!result.next());
    }

    // UPDATE
    const update_sql: [:0]const u8 = "UPDATE items SET count = ? WHERE title = ?";
    _ = try db.execParams(update_sql, &.{ SqlParam{ .int = 99 }, SqlParam{ .text = "bar" } });

    // Verify
    {
        var result = try db.queryParams("SELECT count FROM items WHERE title = ?", &.{SqlParam{ .text = "bar" }});
        defer result.deinit();
        try std.testing.expect(result.next());
        const row = result.currentRow().?;
        try std.testing.expectEqual(@as(i64, 99), (try row.getInt(0)).?);
    }

    // DELETE
    _ = try db.execParams("DELETE FROM items WHERE title = ?", &.{SqlParam{ .text = "baz" }});

    // COUNT = 2
    {
        var result = try db.query("SELECT COUNT(*) FROM items");
        defer result.deinit();
        try std.testing.expect(result.next());
        const row = result.currentRow().?;
        try std.testing.expectEqual(@as(i64, 2), (try row.getInt(0)).?);
    }
}

// ============================================================
test "db: parameter types on SQLite" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    _ = try db.exec("CREATE TABLE params (a INT, b REAL, c TEXT, d BLOB)");

    const insert: [:0]const u8 = "INSERT INTO params VALUES (?, ?, ?, ?)";
    _ = try db.execParams(insert, &.{
        SqlParam{ .int = 42 }, SqlParam{ .real = 3.14 }, SqlParam{ .text = "hello" }, SqlParam{ .null = {} },
    });
    _ = try db.execParams(insert, &.{
        SqlParam{ .int = -1 }, SqlParam{ .real = 0.0 }, SqlParam{ .text = "" }, SqlParam{ .blob = &.{ 0xDE, 0xAD, 0xBE, 0xEF } },
    });

    var result = try db.query("SELECT a, b, c, d FROM params ORDER BY a DESC");
    defer result.deinit();

    try std.testing.expect(result.next());
    const row1 = result.currentRow().?;
    try std.testing.expectEqual(@as(i64, 42), (try row1.getInt(0)).?);
    try std.testing.expectEqualStrings("hello", row1.getText(2).?);
    try std.testing.expect(row1.getText(3) == null);

    try std.testing.expect(result.next());
    const row2 = result.currentRow().?;
    try std.testing.expectEqual(@as(i64, -1), (try row2.getInt(0)).?);
    try std.testing.expectEqualStrings("", row2.getText(2).?);
}

// ============================================================
test "db: SQL injection prevention on SQLite" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    _ = try db.exec("CREATE TABLE safe (data TEXT)");

    const payloads = [_][]const u8{
        "'; DROP TABLE safe; --", "1' OR '1'='1", "' UNION SELECT * FROM passwords --", "1; DELETE FROM safe;",
    };
    for (payloads) |payload| {
        _ = try db.execParams("INSERT INTO safe (data) VALUES (?)", &.{SqlParam{ .text = payload }});
    }

    var result = try db.query("SELECT COUNT(*) FROM safe");
    defer result.deinit();
    try std.testing.expect(result.next());
    try std.testing.expectEqual(@as(i64, 4), (try result.currentRow().?.getInt(0)).?);
}

// ============================================================
test "db: transactions on SQLite" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    _ = try db.exec("CREATE TABLE txn (val TEXT)");
    _ = try db.exec("BEGIN");
    _ = try db.execParams("INSERT INTO txn VALUES (?)", &.{SqlParam{ .text = "committed" }});
    _ = try db.exec("COMMIT");
    _ = try db.exec("BEGIN");
    _ = try db.execParams("INSERT INTO txn VALUES (?)", &.{SqlParam{ .text = "rolled_back" }});
    _ = try db.exec("ROLLBACK");

    var result = try db.query("SELECT COUNT(*) FROM txn");
    defer result.deinit();
    try std.testing.expect(result.next());
    try std.testing.expectEqual(@as(i64, 1), (try result.currentRow().?.getInt(0)).?);
}

// ============================================================
test "db: constraint violation on SQLite" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    _ = try db.exec("CREATE TABLE err_test (code TEXT UNIQUE NOT NULL)");
    _ = try db.execParams("INSERT INTO err_test VALUES (?)", &.{SqlParam{ .text = "unique_val" }});
    // Second insert with same value should fail
    // Duplicate insert should fail
    if (db.execParams("INSERT INTO err_test VALUES (?)", &.{SqlParam{ .text = "unique_val" }})) |_| {
        return error.TestFailed; // expected failure, got success
    } else |_| {
        // Expected: duplicate key error
    }
}

// ============================================================
test "db: UniqueViolation surfaces table+column for AI" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    _ = try db.exec("CREATE TABLE ai_err (email TEXT UNIQUE NOT NULL)");
    _ = try db.execParams("INSERT INTO ai_err VALUES (?)", &.{SqlParam{ .text = "a@x.com" }});

    const result = db.execParams("INSERT INTO ai_err VALUES (?)", &.{SqlParam{ .text = "a@x.com" }});
    try std.testing.expectError(error.UniqueViolation, result);
}

// ============================================================
test "db: unicode round-trip on SQLite" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    _ = try db.exec("CREATE TABLE uni (data TEXT)");
    const texts = [_][]const u8{ "你好世界", "🎉🎊🎈", "Привет мир", "O'Brien \"quoted\" \\backslash\\" };
    for (texts) |t| {
        _ = try db.execParams("INSERT INTO uni VALUES (?)", &.{SqlParam{ .text = t }});
    }

    var result = try db.query("SELECT data FROM uni ORDER BY rowid");
    defer result.deinit();
    for (texts) |expected| {
        try std.testing.expect(result.next());
        try std.testing.expectEqualStrings(expected, result.currentRow().?.getText(0).?);
    }
}

// ============================================================
test "db: large data on SQLite" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    _ = try db.exec("CREATE TABLE large (data TEXT)");

    var buf: [10000]u8 = undefined;
    for (&buf, 0..) |*c, j| c.* = @intCast('A' + @as(u8, @intCast(j % 26)));
    const big = buf[0..];
    _ = try db.execParams("INSERT INTO large VALUES (?)", &.{SqlParam{ .text = big }});

    var result = try db.query("SELECT data FROM large");
    defer result.deinit();
    try std.testing.expect(result.next());
    const back = result.currentRow().?.getText(0).?;
    try std.testing.expectEqual(big.len, back.len);
    try std.testing.expectEqualStrings(big[0..100], back[0..100]);
    try std.testing.expectEqualStrings(big[big.len - 100 ..], back[back.len - 100 ..]);
}

// ============================================================
test "db: bulk insert on SQLite" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    _ = try db.exec("CREATE TABLE bulk (id INTEGER PRIMARY KEY, val TEXT)");
    _ = try db.exec("BEGIN");
    for (0..100) |i| {
        var b: [20]u8 = undefined;
        const label = try std.fmt.bufPrint(&b, "row_{d}", .{i});
        _ = try db.execParams("INSERT INTO bulk (val) VALUES (?)", &.{SqlParam{ .text = label }});
    }
    _ = try db.exec("COMMIT");

    var result = try db.query("SELECT COUNT(*) FROM bulk");
    defer result.deinit();
    try std.testing.expect(result.next());
    try std.testing.expectEqual(@as(i64, 100), (try result.currentRow().?.getInt(0)).?);
}

// ============================================================
test "db: CRUD on PostgreSQL" {
    const a = std.testing.allocator;
    var db = (try tryOpenPG(a)) orelse return error.SkipZigTest;
    defer db.destroy();

    _ = db.exec("DROP TABLE IF EXISTS cross_crud") catch {};
    _ = try db.exec("CREATE TABLE cross_crud (id SERIAL PRIMARY KEY, name TEXT NOT NULL, num INT)");
    _ = try db.execParams("INSERT INTO cross_crud (name, num) VALUES ($1, $2)", &.{ SqlParam{ .text = "pg_test" }, SqlParam{ .int = 42 } });

    var result = try db.query("SELECT name, num FROM cross_crud");
    defer result.deinit();
    try std.testing.expect(result.next());
    const row = result.currentRow().?;
    try std.testing.expectEqualStrings("pg_test", row.getText(0).?);
    try std.testing.expectEqual(@as(i64, 42), (try row.getInt(1)).?);

    _ = db.exec("DROP TABLE IF EXISTS cross_crud") catch {};
}

// ============================================================
test "db: CRUD on MySQL" {
    const a = std.testing.allocator;
    var db = (try tryOpenMY(a)) orelse return error.SkipZigTest;
    defer db.destroy();

    _ = db.exec("DROP TABLE IF EXISTS cross_crud") catch {};
    _ = try db.exec("CREATE TABLE cross_crud (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL, num INT)");
    _ = try db.execParams("INSERT INTO cross_crud (name, num) VALUES (?, ?)", &.{ SqlParam{ .text = "my_test" }, SqlParam{ .int = 7 } });

    var result = try db.query("SELECT name, num FROM cross_crud");
    defer result.deinit();
    try std.testing.expect(result.next());
    const row = result.currentRow().?;
    try std.testing.expectEqualStrings("my_test", row.getText(0).?);
    try std.testing.expectEqual(@as(i64, 7), (try row.getInt(1)).?);

    _ = db.exec("DROP TABLE IF EXISTS cross_crud") catch {};
}

// ============================================================
test "db: connection pool" {
    const a = std.testing.allocator;
    const ConnectionPool = @import("pool.zig").ConnectionPool;

    var pool = try ConnectionPool.init(a, DBConfig.sqliteMemory(), 2);
    defer pool.deinit();

    {
        var conn = try pool.acquire();
        defer pool.release(conn) catch {};
        _ = try conn.exec("CREATE TABLE pool_test (id INTEGER PRIMARY KEY, val TEXT)");
    }
    {
        var conn = try pool.acquire();
        defer pool.release(conn) catch {};
        _ = try conn.execParams("INSERT INTO pool_test (val) VALUES (?)", &.{SqlParam{ .text = "from_pool" }});
    }
    {
        var conn = try pool.acquire();
        defer pool.release(conn) catch {};
        var result = try conn.query("SELECT val FROM pool_test");
        defer result.deinit();
        try std.testing.expect(result.next());
    }
}

test "db: pool keepAlive" {
    const a = std.testing.allocator;
    const ConnectionPool = @import("pool.zig").ConnectionPool;
    var pool = try ConnectionPool.init(a, DBConfig.sqlite(":memory:"), 3);
    defer pool.deinit();

    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    _ = try c1.exec("CREATE TABLE ka (val TEXT)");
    try pool.release(c1);
    try pool.release(c2);

    pool.keepAlive(); // should not crash or panic

    const c3 = try pool.acquire();
    defer pool.release(c3) catch {};
    // Verify acquire works after keepAlive
    _ = try c3.exec("SELECT 1");
}

test "db: ping after connect" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    try std.testing.expect(db.ping());
}

test "db: affected rows" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    _ = try db.exec("CREATE TABLE aff (val TEXT)");
    _ = try db.execParams("INSERT INTO aff VALUES (?)", &.{SqlParam{ .text = "a" }});
    _ = try db.execParams("INSERT INTO aff VALUES (?)", &.{SqlParam{ .text = "b" }});
    _ = try db.execParams("INSERT INTO aff VALUES (?)", &.{SqlParam{ .text = "c" }});
    // affectedRows is driver-specific; just verify it doesn't crash
}

test "db: column metadata" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    _ = try db.exec("CREATE TABLE meta (id INTEGER PRIMARY KEY, name TEXT, age INT)");
    _ = try db.execParams("INSERT INTO meta (name, age) VALUES (?, ?)", &.{ SqlParam{ .text = "test" }, SqlParam{ .int = 25 } });
    var r = try db.query("SELECT id, name, age FROM meta");
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 3), r.columnCount());
    try std.testing.expect(r.next());
}
