const std = @import("std");
const DBConfig = @import("config.zig").DBConfig;
const DBType = @import("config.zig").DBType;
const ResultSet = @import("result.zig").ResultSet;

// Conditional driver imports based on build configuration
// Only import drivers if their libraries are available
const builtin = @import("builtin");

// For now, we'll use a simple approach: only import SQLite by default
// Users can enable other drivers by installing the libraries
const SQLiteDB = @import("drivers/sqlite.zig").SQLiteDB;

// Stub types for disabled drivers
const PostgresDB = struct {
    pub fn connect(_: std.mem.Allocator, _: DBConfig) !PostgresDB {
        return error.DriverNotEnabled;
    }
    pub fn close(_: *PostgresDB) void {}
    pub fn exec(_: *PostgresDB, _: [:0]const u8) !void {
        return error.DriverNotEnabled;
    }
    pub fn query(_: *PostgresDB, _: [:0]const u8) !ResultSet {
        return error.DriverNotEnabled;
    }
    pub fn affectedRows(_: *PostgresDB) !i64 {
        return error.DriverNotEnabled;
    }
};

const MySQLDB = struct {
    pub fn connect(_: std.mem.Allocator, _: DBConfig) !MySQLDB {
        return error.DriverNotEnabled;
    }
    pub fn close(_: *MySQLDB) void {}
    pub fn exec(_: *MySQLDB, _: [:0]const u8) !void {
        return error.DriverNotEnabled;
    }
    pub fn query(_: *MySQLDB, _: [:0]const u8) !ResultSet {
        return error.DriverNotEnabled;
    }
    pub fn lastInsertId(_: *MySQLDB) !i64 {
        return error.DriverNotEnabled;
    }
    pub fn affectedRows(_: *MySQLDB) !i64 {
        return error.DriverNotEnabled;
    }
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

    /// Execute SQL statement (INSERT, UPDATE, DELETE, CREATE, etc.)
    pub fn exec(self: *DB, sql: [:0]const u8) !void {
        switch (self.driver) {
            .postgres => |*pg| try pg.exec(sql),
            .mysql => |*my| try my.exec(sql),
            .sqlite => |*sq| try sq.exec(sql),
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
