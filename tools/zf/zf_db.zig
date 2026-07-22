//! ZfDb — unified SQLite / PostgreSQL / MySQL handle for `zf migrate` / `zf seed`.
const std = @import("std");
const zf_cfg = @import("zf_cfg");

pub const sqlite_c = @import("c_sqlite3");
pub const pg_c = if (zf_cfg.enable_pg) @import("c_pg") else PgDriverStub;
pub const mysql_c = if (zf_cfg.enable_my) @import("c_mysql") else MySqlDriverStub;

// Stubs so the zf CLI compiles when PostgreSQL / MySQL drivers are not enabled.
// The real code paths check zf_cfg.enable_* at runtime and return clear errors.
const PgDriverStub = struct {
    pub const PGconn = opaque {};
    pub const PGresult = opaque {};
    pub const CONNECTION_OK: c_int = 0;
    pub const CONNECTION_BAD: c_int = 1;
    pub const PGRES_COMMAND_OK: c_int = 0;
    pub const PGRES_TUPLES_OK: c_int = 0;
    pub fn PQconnectdb(_: [*:0]const u8) ?*PGconn {
        return null;
    }
    pub fn PQstatus(_: ?*PGconn) c_int {
        return CONNECTION_BAD;
    }
    pub fn PQerrorMessage(_: ?*PGconn) [*:0]const u8 {
        return "PG not enabled";
    }
    pub fn PQfinish(_: ?*PGconn) void {}
    pub fn PQexec(_: ?*PGconn, _: [*:0]const u8) ?*PGresult {
        return null;
    }
    pub fn PQresultStatus(_: ?*PGresult) c_int {
        return 0;
    }
    pub fn PQclear(_: ?*PGresult) void {}
    pub fn PQntuples(_: ?*PGresult) c_int {
        return 0;
    }
    pub fn PQgetvalue(_: ?*PGresult, _: c_int, _: c_int) [*:0]const u8 {
        return "";
    }
    pub fn PQgetisnull(_: ?*PGresult, _: c_int, _: c_int) c_int {
        return 1;
    }
};

const MySqlDriverStub = struct {
    pub const MYSQL = opaque {};
    pub const MYSQL_RES = opaque {};
    pub fn mysql_init(_: ?*MYSQL) ?*MYSQL {
        return null;
    }
    pub fn mysql_real_connect(_: ?*MYSQL, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: c_uint, _: ?[*:0]const u8, _: c_ulong) ?*MYSQL {
        return null;
    }
    pub fn mysql_error(_: ?*MYSQL) [*:0]const u8 {
        return "MySQL not enabled";
    }
    pub fn mysql_close(_: ?*MYSQL) void {}
    pub fn mysql_query(_: ?*MYSQL, _: [*:0]const u8) c_int {
        return 1;
    }
    pub fn mysql_store_result(_: ?*MYSQL) ?*MYSQL_RES {
        return null;
    }
    pub fn mysql_free_result(_: ?*MYSQL_RES) void {}
    pub fn mysql_num_rows(_: ?*MYSQL_RES) c_ulong {
        return 0;
    }
    pub fn mysql_fetch_row(_: ?*MYSQL_RES) ?[*]?[*:0]const u8 {
        return null;
    }
    pub fn mysql_fetch_lengths(_: ?*MYSQL_RES) ?[*]c_ulong {
        return null;
    }
};

pub const DriverTag = enum { sqlite, postgres, mysql };

pub fn driverTagFromEnv() DriverTag {
    const raw = std.c.getenv("ZFINAL_DB_TYPE") orelse return .sqlite;
    const s = std.mem.sliceTo(raw, 0);
    if (std.mem.eql(u8, s, "postgres") or std.mem.eql(u8, s, "pg") or std.mem.eql(u8, s, "postgresql")) return .postgres;
    if (std.mem.eql(u8, s, "mysql") or std.mem.eql(u8, s, "my")) return .mysql;
    return .sqlite;
}

pub fn allocZ(allocator: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const buf = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(buf, s);
    return buf;
}

pub fn getEnvZ(allocator: std.mem.Allocator, name: [*:0]const u8, default: []const u8) ![:0]const u8 {
    const raw = std.c.getenv(name);
    const slice = if (raw) |r| std.mem.sliceTo(r, 0) else default;
    return allocZ(allocator, slice);
}

pub fn escapeSqlString(allocator: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const count = std.mem.count(u8, s, "'");
    const buf = try allocator.allocSentinel(u8, s.len + count, 0);
    var i: usize = 0;
    for (s) |c| {
        if (c == '\'') {
            buf[i] = '\'';
            i += 1;
        }
        buf[i] = c;
        i += 1;
    }
    return buf[0..i :0];
}

pub fn formatSqlZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    return allocZ(allocator, s);
}

pub const PgDsnParts = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,

    fn deinit(self: PgDsnParts, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.user);
        allocator.free(self.password);
        allocator.free(self.database);
    }
};

pub fn parsePgDsn(allocator: std.mem.Allocator, url: []const u8) !PgDsnParts {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "postgresql://")) {
        rest = rest["postgresql://".len..];
    } else if (std.mem.startsWith(u8, rest, "postgres://")) {
        rest = rest["postgres://".len..];
    } else {
        return error.InvalidDsn;
    }

    var user: []const u8 = try allocator.dupe(u8, "postgres");
    errdefer allocator.free(user);
    var password: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(password);
    var host: []const u8 = try allocator.dupe(u8, "localhost");
    errdefer allocator.free(host);
    var port: u16 = 5432;
    var database: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(database);

    if (std.mem.indexOfScalar(u8, rest, '@')) |at_pos| {
        const up = rest[0..at_pos];
        rest = rest[at_pos + 1 ..];
        allocator.free(user);
        allocator.free(password);
        if (std.mem.indexOfScalar(u8, up, ':')) |colon| {
            user = try allocator.dupe(u8, up[0..colon]);
            password = try allocator.dupe(u8, up[colon + 1 ..]);
        } else {
            user = try allocator.dupe(u8, up);
            password = try allocator.dupe(u8, "");
        }
    }

    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const hp = rest[0..slash];
        allocator.free(database);
        database = try allocator.dupe(u8, rest[slash + 1 ..]);
        if (std.mem.indexOfScalar(u8, hp, ':')) |colon| {
            allocator.free(host);
            host = try allocator.dupe(u8, hp[0..colon]);
            port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch 5432;
        } else if (hp.len > 0) {
            allocator.free(host);
            host = try allocator.dupe(u8, hp);
        }
    } else {
        allocator.free(database);
        database = try allocator.dupe(u8, rest);
    }

    return .{
        .host = host,
        .port = port,
        .user = user,
        .password = password,
        .database = database,
    };
}

pub fn buildPgConninfo(allocator: std.mem.Allocator) ![:0]const u8 {
    const dsn = std.c.getenv("ZFINAL_PG_DSN");
    if (dsn) |d| {
        const s = std.mem.sliceTo(d, 0);
        if (std.mem.startsWith(u8, s, "postgres://") or std.mem.startsWith(u8, s, "postgresql://")) {
            var parsed = try parsePgDsn(allocator, s);
            defer parsed.deinit(allocator);
            return allocPgConninfo(allocator, parsed.host, parsed.port, parsed.user, parsed.password, parsed.database);
        }
        return allocZ(allocator, s);
    }

    const host = try getEnvZ(allocator, "ZF_PG_HOST", "localhost");
    defer allocator.free(host);
    const port_str = try getEnvZ(allocator, "ZF_PG_PORT", "5432");
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str[0..port_str.len], 10) catch 5432;
    const user = try getEnvZ(allocator, "ZF_PG_USER", "postgres");
    defer allocator.free(user);
    const database = try getEnvZ(allocator, "ZF_PG_DATABASE", "zfinal");
    defer allocator.free(database);
    const password: []const u8 = blk: {
        const raw = std.c.getenv("ZF_PG_PASSWORD");
        break :blk if (raw) |r| std.mem.sliceTo(r, 0) else "";
    };
    return allocPgConninfo(allocator, host, port, user, password, database);
}

pub fn allocPgConninfo(allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, password: []const u8, database: []const u8) ![:0]const u8 {
    var buf: [1024]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "host={s} port={d} dbname={s} user={s} password={s} client_encoding=UTF8", .{ host, port, database, user, password });
    return allocZ(allocator, s);
}

pub const MyDsnParts = struct {
    host: [:0]const u8,
    port: u16,
    user: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,

    fn deinit(self: MyDsnParts, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.user);
        allocator.free(self.password);
        allocator.free(self.database);
    }
};

pub fn parseMyDsn(allocator: std.mem.Allocator, url: []const u8) !MyDsnParts {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "mysql://")) {
        rest = rest["mysql://".len..];
    } else {
        return error.InvalidDsn;
    }

    var user: [:0]const u8 = try allocZ(allocator, "root");
    errdefer allocator.free(user);
    var password: [:0]const u8 = try allocZ(allocator, "");
    errdefer allocator.free(password);
    var host: [:0]const u8 = try allocZ(allocator, "localhost");
    errdefer allocator.free(host);
    var port: u16 = 3306;
    var database: [:0]const u8 = try allocZ(allocator, "");
    errdefer allocator.free(database);

    if (std.mem.indexOfScalar(u8, rest, '@')) |at_pos| {
        const up = rest[0..at_pos];
        rest = rest[at_pos + 1 ..];
        allocator.free(user);
        allocator.free(password);
        if (std.mem.indexOfScalar(u8, up, ':')) |colon| {
            user = try allocZ(allocator, up[0..colon]);
            password = try allocZ(allocator, up[colon + 1 ..]);
        } else {
            user = try allocZ(allocator, up);
            password = try allocZ(allocator, "");
        }
    }

    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const hp = rest[0..slash];
        allocator.free(database);
        database = try allocZ(allocator, rest[slash + 1 ..]);
        if (std.mem.indexOfScalar(u8, hp, ':')) |colon| {
            allocator.free(host);
            host = try allocZ(allocator, hp[0..colon]);
            port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch 3306;
        } else if (hp.len > 0) {
            allocator.free(host);
            host = try allocZ(allocator, hp);
        }
    } else {
        allocator.free(database);
        database = try allocZ(allocator, rest);
    }

    return .{
        .host = host,
        .port = port,
        .user = user,
        .password = password,
        .database = database,
    };
}

pub fn buildMyConfig(allocator: std.mem.Allocator) !MyDsnParts {
    const dsn = std.c.getenv("ZFINAL_MY_DSN");
    if (dsn) |d| {
        return parseMyDsn(allocator, std.mem.sliceTo(d, 0));
    }

    const host = try getEnvZ(allocator, "ZF_MY_HOST", "localhost");
    errdefer allocator.free(host);
    const port_str = try getEnvZ(allocator, "ZF_MY_PORT", "3306");
    const port = std.fmt.parseInt(u16, port_str[0..port_str.len], 10) catch 3306;
    allocator.free(port_str);
    const user = try getEnvZ(allocator, "ZF_MY_USER", "root");
    errdefer allocator.free(user);
    const database = try getEnvZ(allocator, "ZF_MY_DATABASE", "zfinal");
    errdefer allocator.free(database);
    const password: [:0]const u8 = blk: {
        const raw = std.c.getenv("ZF_MY_PASSWORD");
        const slice = if (raw) |r| std.mem.sliceTo(r, 0) else "";
        break :blk try allocZ(allocator, slice);
    };
    errdefer allocator.free(password);
    return .{
        .host = host,
        .port = port,
        .user = user,
        .password = password,
        .database = database,
    };
}

pub const SqliteDb = struct {
    db: *sqlite_c.sqlite3,
    allocator: std.mem.Allocator,

    fn open(allocator: std.mem.Allocator, path: [:0]const u8) !SqliteDb {
        var db: ?*sqlite_c.sqlite3 = null;
        const rc = sqlite_c.sqlite3_open(path.ptr, &db);
        if (rc != sqlite_c.SQLITE_OK or db == null) {
            std.debug.print("Failed to open SQLite database: {s}\n", .{path});
            return error.DbOpenFailed;
        }
        return .{ .db = db.?, .allocator = allocator };
    }

    fn close(self: SqliteDb) void {
        _ = sqlite_c.sqlite3_close(self.db);
    }

    fn exec(self: SqliteDb, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        if (sqlite_c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg) != sqlite_c.SQLITE_OK) {
            std.debug.print("SQLite exec error: {s}\n", .{if (err_msg) |e| std.mem.sliceTo(e, 0) else "(no message)"});
            return error.SqlExecFailed;
        }
    }

    fn queryExists(self: SqliteDb, sql: [:0]const u8) !bool {
        var stmt: ?*sqlite_c.sqlite3_stmt = null;
        if (sqlite_c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != sqlite_c.SQLITE_OK) return false;
        defer _ = sqlite_c.sqlite3_finalize(stmt);
        return sqlite_c.sqlite3_step(stmt) == sqlite_c.SQLITE_ROW;
    }

    fn queryText(self: SqliteDb, allocator: std.mem.Allocator, sql: [:0]const u8) !?[]const u8 {
        var stmt: ?*sqlite_c.sqlite3_stmt = null;
        if (sqlite_c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != sqlite_c.SQLITE_OK) return null;
        defer _ = sqlite_c.sqlite3_finalize(stmt);
        if (sqlite_c.sqlite3_step(stmt) != sqlite_c.SQLITE_ROW) return null;
        const raw = sqlite_c.sqlite3_column_text(stmt, 0) orelse return null;
        return try allocator.dupe(u8, std.mem.sliceTo(raw, 0));
    }

    fn ensureMigrationsTable(self: SqliteDb) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS _zfinal_migrations (
            \\  version TEXT PRIMARY KEY,
            \\  filename TEXT NOT NULL,
            \\  applied_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\  checksum INTEGER NOT NULL
            \\);
        ;
        try self.exec(sql);
    }

    fn ensureSeedsTable(self: SqliteDb) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS _zfinal_seeds (
            \\  name TEXT PRIMARY KEY,
            \\  filename TEXT NOT NULL,
            \\  applied_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\  checksum INTEGER NOT NULL
            \\);
        ;
        try self.exec(sql);
    }
};

pub const PostgresDb = struct {
    conn: *pg_c.PGconn,
    allocator: std.mem.Allocator,

    fn open(allocator: std.mem.Allocator, conninfo: [:0]const u8) !PostgresDb {
        if (!zf_cfg.enable_pg) {
            std.debug.print("PostgreSQL support not enabled. Rebuild with: zig build install-zf -Denable-pg\n", .{});
            return error.PgNotEnabled;
        }
        const conn = pg_c.PQconnectdb(conninfo.ptr) orelse return error.PgConnectFailed;
        if (pg_c.PQstatus(conn) != pg_c.CONNECTION_OK) {
            std.debug.print("PostgreSQL connect failed: {s}\n", .{pg_c.PQerrorMessage(conn)});
            pg_c.PQfinish(conn);
            return error.PgConnectFailed;
        }
        return .{ .conn = conn, .allocator = allocator };
    }

    fn close(self: PostgresDb) void {
        pg_c.PQfinish(self.conn);
    }

    fn exec(self: PostgresDb, sql: [:0]const u8) !void {
        const res = pg_c.PQexec(self.conn, sql.ptr) orelse return error.SqlExecFailed;
        defer pg_c.PQclear(res);
        if (pg_c.PQresultStatus(res) != pg_c.PGRES_COMMAND_OK) {
            std.debug.print("PostgreSQL exec error: {s}\n", .{pg_c.PQerrorMessage(self.conn)});
            return error.SqlExecFailed;
        }
    }

    fn queryExists(self: PostgresDb, sql: [:0]const u8) !bool {
        const res = pg_c.PQexec(self.conn, sql.ptr) orelse return false;
        defer pg_c.PQclear(res);
        if (pg_c.PQresultStatus(res) != pg_c.PGRES_TUPLES_OK) return false;
        return pg_c.PQntuples(res) > 0;
    }

    fn queryText(self: PostgresDb, allocator: std.mem.Allocator, sql: [:0]const u8) !?[]const u8 {
        const res = pg_c.PQexec(self.conn, sql.ptr) orelse return null;
        defer pg_c.PQclear(res);
        if (pg_c.PQresultStatus(res) != pg_c.PGRES_TUPLES_OK) return null;
        if (pg_c.PQntuples(res) == 0) return null;
        if (pg_c.PQgetisnull(res, 0, 0) != 0) return null;
        const raw = pg_c.PQgetvalue(res, 0, 0);
        return try allocator.dupe(u8, std.mem.sliceTo(raw, 0));
    }

    fn ensureMigrationsTable(self: PostgresDb) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS _zfinal_migrations (
            \\  version TEXT PRIMARY KEY,
            \\  filename TEXT NOT NULL,
            \\  applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  checksum BIGINT NOT NULL
            \\);
        ;
        try self.exec(sql);
    }

    fn ensureSeedsTable(self: PostgresDb) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS _zfinal_seeds (
            \\  name TEXT PRIMARY KEY,
            \\  filename TEXT NOT NULL,
            \\  applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  checksum BIGINT NOT NULL
            \\);
        ;
        try self.exec(sql);
    }
};

pub const MySqlDb = struct {
    conn: *mysql_c.MYSQL,
    allocator: std.mem.Allocator,

    fn open(allocator: std.mem.Allocator, host: [:0]const u8, port: u16, user: [:0]const u8, password: ?[:0]const u8, database: [:0]const u8) !MySqlDb {
        if (!zf_cfg.enable_my) {
            std.debug.print("MySQL support not enabled. Rebuild with: zig build install-zf -Denable-mysql\n", .{});
            return error.MyNotEnabled;
        }
        const conn = mysql_c.mysql_init(null) orelse return error.MyConnectFailed;
        const pw_ptr = if (password) |p| p.ptr else null;
        if (mysql_c.mysql_real_connect(conn, host.ptr, user.ptr, pw_ptr, database.ptr, port, null, 0) == null) {
            std.debug.print("MySQL connect failed: {s}\n", .{mysql_c.mysql_error(conn)});
            mysql_c.mysql_close(conn);
            return error.MyConnectFailed;
        }
        return .{ .conn = conn, .allocator = allocator };
    }

    fn close(self: MySqlDb) void {
        mysql_c.mysql_close(self.conn);
    }

    fn exec(self: MySqlDb, sql: [:0]const u8) !void {
        if (mysql_c.mysql_query(self.conn, sql.ptr) != 0) {
            std.debug.print("MySQL exec error: {s}\n", .{mysql_c.mysql_error(self.conn)});
            return error.SqlExecFailed;
        }
        const res = mysql_c.mysql_store_result(self.conn);
        if (res) |r| mysql_c.mysql_free_result(r);
    }

    fn queryExists(self: MySqlDb, sql: [:0]const u8) !bool {
        if (mysql_c.mysql_query(self.conn, sql.ptr) != 0) return false;
        const res = mysql_c.mysql_store_result(self.conn) orelse return false;
        defer mysql_c.mysql_free_result(res);
        return mysql_c.mysql_num_rows(res) > 0;
    }

    fn queryText(self: MySqlDb, allocator: std.mem.Allocator, sql: [:0]const u8) !?[]const u8 {
        if (mysql_c.mysql_query(self.conn, sql.ptr) != 0) return null;
        const res = mysql_c.mysql_store_result(self.conn) orelse return null;
        defer mysql_c.mysql_free_result(res);
        const row = mysql_c.mysql_fetch_row(res) orelse return null;
        const lengths = mysql_c.mysql_fetch_lengths(res) orelse return null;
        const raw = row[0] orelse return null;
        return try allocator.dupe(u8, raw[0..lengths[0]]);
    }

    fn ensureMigrationsTable(self: MySqlDb) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS _zfinal_migrations (
            \\  version VARCHAR(255) PRIMARY KEY,
            \\  filename VARCHAR(255) NOT NULL,
            \\  applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  checksum BIGINT NOT NULL
            \\);
        ;
        try self.exec(sql);
    }

    fn ensureSeedsTable(self: MySqlDb) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS _zfinal_seeds (
            \\  name VARCHAR(255) PRIMARY KEY,
            \\  filename VARCHAR(255) NOT NULL,
            \\  applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  checksum BIGINT NOT NULL
            \\);
        ;
        try self.exec(sql);
    }
};

pub const ZfDb = union(DriverTag) {
    sqlite: SqliteDb,
    postgres: PostgresDb,
    mysql: MySqlDb,

    pub fn deinit(self: *ZfDb) void {
        switch (self.*) {
            .sqlite => |impl| impl.close(),
            .postgres => |impl| impl.close(),
            .mysql => |impl| impl.close(),
        }
    }

    pub fn exec(self: ZfDb, sql: [:0]const u8) !void {
        switch (self) {
            .sqlite => |impl| return impl.exec(sql),
            .postgres => |impl| return impl.exec(sql),
            .mysql => |impl| return impl.exec(sql),
        }
    }

    pub fn queryExists(self: ZfDb, sql: [:0]const u8) !bool {
        switch (self) {
            .sqlite => |impl| return impl.queryExists(sql),
            .postgres => |impl| return impl.queryExists(sql),
            .mysql => |impl| return impl.queryExists(sql),
        }
    }

    pub fn queryText(self: ZfDb, allocator: std.mem.Allocator, sql: [:0]const u8) !?[]const u8 {
        switch (self) {
            .sqlite => |impl| return impl.queryText(allocator, sql),
            .postgres => |impl| return impl.queryText(allocator, sql),
            .mysql => |impl| return impl.queryText(allocator, sql),
        }
    }

    pub fn ensureMigrationsTable(self: ZfDb) !void {
        switch (self) {
            .sqlite => |impl| return impl.ensureMigrationsTable(),
            .postgres => |impl| return impl.ensureMigrationsTable(),
            .mysql => |impl| return impl.ensureMigrationsTable(),
        }
    }

    pub fn ensureSeedsTable(self: ZfDb) !void {
        switch (self) {
            .sqlite => |impl| return impl.ensureSeedsTable(),
            .postgres => |impl| return impl.ensureSeedsTable(),
            .mysql => |impl| return impl.ensureSeedsTable(),
        }
    }
};

pub fn openZfinalDb(allocator: std.mem.Allocator) !ZfDb {
    switch (driverTagFromEnv()) {
        .sqlite => {
            const path = try getEnvZ(allocator, "ZFINAL_DB_PATH", "zf.db");
            defer allocator.free(path);
            return ZfDb{ .sqlite = try SqliteDb.open(allocator, path) };
        },
        .postgres => {
            const conninfo = try buildPgConninfo(allocator);
            defer allocator.free(conninfo);
            return ZfDb{ .postgres = try PostgresDb.open(allocator, conninfo) };
        },
        .mysql => {
            var cfg = try buildMyConfig(allocator);
            defer cfg.deinit(allocator);
            const pw: ?[:0]const u8 = if (cfg.password.len > 0) cfg.password else null;
            return ZfDb{ .mysql = try MySqlDb.open(allocator, cfg.host, cfg.port, cfg.user, pw, cfg.database) };
        },
    }
}

test "ZfDb helpers compile and default to SQLite" {
    const allocator = std.testing.allocator;
    const escaped = try escapeSqlString(allocator, "it's a test");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("it''s a test", escaped);
    try std.testing.expect(driverTagFromEnv() == .sqlite);
}
