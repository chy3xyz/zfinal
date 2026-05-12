const std = @import("std");
const DBConfig = @import("config.zig").DBConfig;
const DBType = @import("config.zig").DBType;
const ResultSet = @import("result.zig").ResultSet;
const SqlParam = @import("sql_param.zig").SqlParam;

const builtin = @import("builtin");
const SQLiteDB = @import("drivers/sqlite.zig").SQLiteDB;

// PostgreSQL and MySQL full driver implementations live in drivers/.
// To use them, install the C client library (libpq / libmysqlclient),
// link it in your build.zig, and import the driver directly:
//   const PG = @import("zfinal/db/drivers/postgres.zig").PostgresDB;
//
// The stubs below keep the DB wrapper compilable without native deps.
const PostgresDB = DriverStub;
const MySQLDB = DriverStub;

const DriverStub = struct {
    conn: ?*anyopaque = null,
    allocator: std.mem.Allocator = undefined,
    pub fn connect(_: std.mem.Allocator, _: DBConfig) !@This() { return error.DriverNotEnabled; }
    pub fn close(_: *@This()) void {}
    pub fn ping(_: *@This()) bool { return false; }
    pub fn exec(_: *@This(), _: [:0]const u8) !void { return error.DriverNotEnabled; }
    pub fn execParams(_: *@This(), _: [:0]const u8, _: []const SqlParam) !void { return error.DriverNotEnabled; }
    pub fn query(_: *@This(), _: [:0]const u8) !ResultSet { return error.DriverNotEnabled; }
    pub fn queryParams(_: *@This(), _: [:0]const u8, _: []const SqlParam) !ResultSet { return error.DriverNotEnabled; }
    pub fn lastInsertId(_: *@This()) !i64 { return error.DriverNotEnabled; }
    pub fn affectedRows(_: *@This()) i64 { return 0; }
};

/// Unified database interface
pub const DB = struct {
    driver: Driver,
    allocator: std.mem.Allocator,

    pub const Driver = union(DBType) {
        postgres: PostgresDB,
        mysql: MySQLDB,
        sqlite: SQLiteDB,
    };

    /// Initialize database connection
    pub fn init(allocator: std.mem.Allocator, config: DBConfig) !DB {
        const driver = switch (config.db_type) {
            .postgres => Driver{ .postgres = try PostgresDB.connect(allocator, config) },
            .mysql => Driver{ .mysql = try MySQLDB.connect(allocator, config) },
            .sqlite => Driver{ .sqlite = try SQLiteDB.open(allocator, config) },
        };

        return DB{
            .driver = driver,
            .allocator = allocator,
        };
    }

    /// Close database connection
    pub fn deinit(self: *DB) void {
        switch (self.driver) {
            .postgres => |*pg| pg.close(),
            .mysql => |*my| my.close(),
            .sqlite => |*sq| sq.close(),
        }
    }

    /// Health check: returns true if the connection is alive.
    pub fn ping(self: *DB) bool {
        switch (self.driver) {
            .postgres => |*pg| return pg.ping(),
            .mysql => |*my| return my.ping(),
            .sqlite => |*sq| return sq.ping(),
        }
    }

    /// Execute SQL statement (INSERT, UPDATE, DELETE, CREATE, etc.)
    pub fn exec(self: *DB, sql: [:0]const u8) !void {
        switch (self.driver) {
            .postgres => |*pg| try pg.exec(sql),
            .mysql => |*my| try my.exec(sql),
            .sqlite => |*sq| try sq.exec(sql),
        }
    }

    /// Execute with parameter binding (safe against SQL injection)
    pub fn execParams(self: *DB, sql: [:0]const u8, params: []const SqlParam) !void {
        switch (self.driver) {
            .postgres => |*pg| try pg.execParams(sql, params),
            .mysql => |*my| try my.execParams(sql, params),
            .sqlite => |*sq| try sq.execParams(sql, params),
        }
    }

    /// Execute query and return result set
    pub fn query(self: *DB, sql: [:0]const u8) !ResultSet {
        return switch (self.driver) {
            .postgres => |*pg| try pg.query(sql),
            .mysql => |*my| try my.query(sql),
            .sqlite => |*sq| try sq.query(sql),
        };
    }

    /// Execute query with parameter binding
    pub fn queryParams(self: *DB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        return switch (self.driver) {
            .postgres => |*pg| try pg.queryParams(sql, params),
            .mysql => |*my| try my.queryParams(sql, params),
            .sqlite => |*sq| try sq.queryParams(sql, params),
        };
    }

    /// Get last insert ID (for auto-increment columns)
    pub fn lastInsertId(self: *DB) !i64 {
        return switch (self.driver) {
            .postgres => error.NotSupported, // Postgres uses RETURNING clause
            .mysql => |*my| try my.lastInsertId(),
            .sqlite => |*sq| sq.lastInsertId(),
        };
    }

    /// Get number of affected rows from last statement
    pub fn affectedRows(self: *DB) !i64 {
        return switch (self.driver) {
            .postgres => |*pg| try pg.affectedRows(),
            .mysql => |*my| try my.affectedRows(),
            .sqlite => |*sq| sq.affectedRows(),
        };
    }

    /// Begin transaction
    pub fn begin(self: *DB) !void {
        try self.exec("BEGIN");
    }

    /// Commit transaction
    pub fn commit(self: *DB) !void {
        try self.exec("COMMIT");
    }

    /// Rollback transaction
    pub fn rollback(self: *DB) !void {
        try self.exec("ROLLBACK");
    }
};
