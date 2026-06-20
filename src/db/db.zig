const std = @import("std");
const DBConfig = @import("config.zig").DBConfig;
const DBType = @import("config.zig").DBType;
const ResultSet = @import("result.zig").ResultSet;
const SqlParam = @import("sql_param.zig").SqlParam;

const builtin = @import("builtin");
const SQLiteDB = @import("drivers/sqlite.zig").SQLiteDB;
const build_opts = @import("build_options");

const PostgresDB = if (build_opts.enable_pg)
    @import("drivers/postgres.zig").PostgresDB
else
    DriverStub;

const MySQLDB = if (build_opts.enable_mysql)
    @import("drivers/mysql.zig").MySQLDB
else
    DriverStub;

const DriverStub = struct {
    conn: ?*anyopaque = null,
    allocator: std.mem.Allocator = undefined,
    pub fn connect(_: std.mem.Allocator, _: DBConfig) !@This() {
        return error.DriverNotEnabled;
    }
    pub fn close(_: *@This()) void {}
    pub fn ping(_: *@This()) bool {
        return false;
    }
    pub fn exec(_: *@This(), _: [:0]const u8) !void {
        return error.DriverNotEnabled;
    }
    pub fn execParams(_: *@This(), _: [:0]const u8, _: []const SqlParam) !void {
        return error.DriverNotEnabled;
    }
    pub fn query(_: *@This(), _: [:0]const u8) !ResultSet {
        return error.DriverNotEnabled;
    }
    pub fn queryParams(_: *@This(), _: [:0]const u8, _: []const SqlParam) !ResultSet {
        return error.DriverNotEnabled;
    }
    pub fn lastInsertId(_: *@This()) !i64 {
        return error.DriverNotEnabled;
    }
    pub fn affectedRows(_: *@This()) i64 {
        return 0;
    }
    // must match MySQLDB.RawBinlogEvent layout
    pub const RawBinlogEvent = struct { buffer: [*c]const u8, size: c_ulong };
    pub fn binlogOpen(_: *@This(), _: [:0]const u8, _: u64) !void {
        return error.DriverNotEnabled;
    }
    pub fn binlogFetch(_: *@This()) !?RawBinlogEvent {
        return error.DriverNotEnabled;
    }
    pub fn binlogClose(_: *@This()) void {}
};

pub const Driver = union(DBType) {
    postgres: PostgresDB,
    mysql: MySQLDB,
    sqlite: SQLiteDB,
};

pub const DB = struct {
    /// Magic sentinel for heap corruption detection. Must be 0xDBDBDBDB.
    /// Checked in guard() before any operation. If corrupted, the struct
    /// was double-freed or the heap was overwritten by an adjacent allocation.
    magic: u32 = 0xDBDBDBDB,
    driver: Driver,
    allocator: std.mem.Allocator,
    /// Set to false when the connection is closed/destroyed.
    /// Checked in ping() to prevent use-after-destroy in pooled connections.
    valid: bool = true,
    /// Acquire/release guard: true while conn is checked out from pool.
    checked_out: bool = false,

    pub const RawBinlogEvent = MySQLDB.RawBinlogEvent;

    /// Allocate and initialize a DB on the heap. Returns *DB to avoid struct copy
/// of driver internals (the Driver union may contain platform-specific handles
/// that don't survive by-value copy with Zig 0.17's debug allocator fill).
pub fn init(allocator: std.mem.Allocator, config: DBConfig) !*DB {
        const db = try allocator.create(DB);
        errdefer allocator.destroy(db);
        const driver = switch (config.db_type) {
            .sqlite => Driver{ .sqlite = try SQLiteDB.open(allocator, config) },
            .postgres => Driver{ .postgres = try PostgresDB.connect(allocator, config) },
            .mysql => Driver{ .mysql = try MySQLDB.connect(allocator, config) },
        };
        db.* = .{ .driver = driver, .allocator = allocator };
        return db;
    }

    pub fn deinit(self: *DB) void {
        self.valid = false;
        switch (self.driver) {
            .postgres => |*d| d.close(),
            .mysql => |*d| d.close(),
            .sqlite => |*d| d.close(),
        }
    }

    /// Close the connection and free the heap allocation.
    pub fn destroy(self: *DB) void {
        self.deinit();
        self.allocator.destroy(self);
    }

    pub fn ping(self: *DB) bool {
        if (self.magic != 0xDBDBDBDB) {
            std.debug.print("DB.magic corrupted on ping: 0x{x}\n", .{self.magic});
            return false;
        }
        if (!self.valid) return false;
        return switch (self.driver) {
            .postgres => |*d| d.ping(),
            .mysql => |*d| d.ping(),
            .sqlite => |*d| d.ping(),
        };
    }

    /// Mark the connection as checked out from the pool.
    /// Caller: pool.acquire().
    pub fn checkOut(self: *DB) void {
        self.checked_out = true;
    }

    /// Mark the connection as returned to the pool.
    /// Caller: pool.release().
    pub fn checkIn(self: *DB) void {
        self.checked_out = false;
    }

    /// Enforce that the connection is checked out + not heap-corrupted.
    fn guard(self: *DB) !void {
        if (self.magic != 0xDBDBDBDB) {
            std.debug.print("DB.magic corrupted: 0x{x}\n", .{self.magic});
            @panic("DB heap corruption detected (magic mismatch)");
        }
        if (!self.checked_out) return error.CheckedOut;
    }

    pub fn exec(self: *DB, sql: [:0]const u8) !void {
        try self.guard();
        switch (self.driver) {
            .postgres => |*d| try d.exec(sql),
            .mysql => |*d| try d.exec(sql),
            .sqlite => |*d| try d.exec(sql),
        }
    }

    pub fn execParams(self: *DB, sql: [:0]const u8, params: []const SqlParam) !void {
        try self.guard();
        switch (self.driver) {
            .postgres => |*d| try d.execParams(sql, params),
            .mysql => |*d| try d.execParams(sql, params),
            .sqlite => |*d| try d.execParams(sql, params),
        }
    }

    pub fn lastInsertId(self: *DB) !i64 {
        return switch (self.driver) {
            .postgres => |*d| d.lastInsertId(),
            .mysql => |*d| d.lastInsertId(),
            .sqlite => |*d| d.lastInsertId(),
        };
    }

    pub fn affectedRows(self: *DB) i64 {
        return switch (self.driver) {
            .postgres => |*d| d.affectedRows(),
            .mysql => |*d| d.affectedRows(),
            .sqlite => |*d| d.affectedRows(),
        };
    }

    pub fn binlogOpen(self: *DB, file: [:0]const u8, pos: u64) !void {
        switch (self.driver) {
            .mysql => |*d| try d.binlogOpen(file, pos),
            else => return error.UnsupportedDriver,
        }
    }

    pub fn binlogFetch(self: *DB) !?RawBinlogEvent {
        return switch (self.driver) {
            .mysql => |*d| try d.binlogFetch(),
            else => error.UnsupportedDriver,
        };
    }

    pub fn binlogClose(self: *DB) void {
        switch (self.driver) {
            .mysql => |*d| d.binlogClose(),
            else => {},
        }
    }

    pub fn query(self: *DB, sql: [:0]const u8) !ResultSet {
        try self.guard();
        return switch (self.driver) {
            .postgres => |*d| d.query(sql),
            .mysql => |*d| d.query(sql),
            .sqlite => |*d| d.query(sql),
        };
    }

    pub fn queryParams(self: *DB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        try self.guard();
        return switch (self.driver) {
            .postgres => |*d| d.queryParams(sql, params),
            .mysql => |*d| d.queryParams(sql, params),
            .sqlite => |*d| d.queryParams(sql, params),
        };
    }
};

test {
    _ = @import("integration_test.zig");
}
