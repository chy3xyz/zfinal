const std = @import("std");
const DBConfig = @import("config.zig").DBConfig;
const DBType = @import("config.zig").DBType;
const Cell = @import("result.zig").Cell;
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
    pub fn prepareCached(_: *@This(), _: [:0]const u8, _: [:0]const u8, _: c_int) !void {
        return error.DriverNotEnabled;
    }
    pub fn execCached(_: *@This(), _: [:0]const u8, _: []const ?[*:0]const u8, _: []const c_int, _: []const c_int, _: c_int) anyerror!*anyopaque {
        return error.DriverNotEnabled;
    }
    pub fn releaseCached(_: *@This(), _: [:0]const u8) void {}
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
    /// Acquire/release guard. Standalone connections (direct DB.init) are
    /// owned by their creator from birth, so this defaults to true.
    /// ConnectionPool flips it: checkIn() on release / pool insertion,
    /// checkOut() on acquire — catching use-after-release of pooled conns.
    checked_out: bool = true,

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

    /// Begin a transaction (BEGIN / START TRANSACTION).
    pub fn begin(self: *DB) !void {
        try self.guard();
        try self.exec("BEGIN");
    }

    /// Commit the current transaction (COMMIT).
    pub fn commit(self: *DB) !void {
        try self.guard();
        try self.exec("COMMIT");
    }

    /// Roll back the current transaction (ROLLBACK).
    pub fn rollback(self: *DB) !void {
        try self.guard();
        try self.exec("ROLLBACK");
    }

    /// Run `body` inside a transaction with automatic commit / rollback.
    ///
    /// If `body` returns normally, the transaction commits. If `body`
    /// returns an error, the transaction rolls back and that error is
    /// propagated. Caller never has to write `begin/commit/rollback`
    /// boilerplate.
    ///
    /// Optional `DeadlockRetry` config: when non-null, the body is
    /// retried up to `cfg.max_retries` times on InnoDB deadlock
    /// (PG SQLSTATE 40P01 / MySQL errno 1213). Each retry rolls back
    /// and re-runs from `BEGIN`.
    ///
    /// IMPORTANT: `body` must be a named function (top-level `fn` or
    /// struct method). Zig 0.17 has a lifetime issue with anonymous
    /// struct literals as comptime function pointers — the body runs
    /// with the parent stack frame already torn down, causing UAF in
    /// subsequent queries. Use a named function or struct method instead.
    ///
    /// Example:
    /// ```zig
    /// const TxnBody = struct {
    ///     fn run(d: *DB) !void {
    ///         try d.execParams("UPDATE ...", &.{...});
    ///         try d.execParams("INSERT ...", &.{...});
    ///     }
    /// };
    /// try db.transaction(null, TxnBody.run);
    /// ```
    pub fn transaction(self: *DB, cfg: ?DeadlockRetry, comptime body: fn (*DB) anyerror!void) !void {
        var attempts: u32 = 0;
        const max = if (cfg) |c| c.max_retries else 0;
        while (true) {
            try self.begin();
            if (body(self)) {
                try self.commit();
                return;
            } else |err| {
                // Always attempt rollback on error. If rollback itself
                // fails, log via stderr but propagate the original error.
                self.rollback() catch |rb_err| {
                    std.debug.print("transaction rollback failed: {s}\n", .{@errorName(rb_err)});
                };
                if (cfg != null and attempts < max and isDeadlockError(err)) {
                    attempts += 1;
                    continue;
                }
                return err;
            }
        }
    }

    /// Generic-returning variant of `transaction`. Use when the body
    /// produces a value (e.g. computed aggregates, generated IDs).
    pub fn transactionResult(
        self: *DB,
        cfg: ?DeadlockRetry,
        comptime T: type,
        comptime body: fn (*DB) anyerror!T,
    ) !T {
        var attempts: u32 = 0;
        const max = if (cfg) |c| c.max_retries else 0;
        while (true) {
            try self.begin();
            if (body(self)) |result| {
                try self.commit();
                return result;
            } else |err| {
                self.rollback() catch |rb_err| {
                    std.debug.print("transaction rollback failed: {s}\n", .{@errorName(rb_err)});
                };
                if (cfg != null and attempts < max and isDeadlockError(err)) {
                    attempts += 1;
                    continue;
                }
                return err;
            }
        }
    }

    /// Run a query that returns a single scalar value (one row, one
    /// column). Returns null when the result set is empty.
    ///
    /// `T` must be one of: `i64`, `f64`, `bool`, `[]const u8` (text).
    /// The driver returns the matching `Cell` variant; we coerce to `T`.
    ///
    /// For `T = []const u8`, the returned slice is heap-allocated via
    /// `allocator` and the caller owns it (must `allocator.free()` when
    /// done). For numeric / bool types the value is copied by value so
    /// no allocator is needed.
    ///
    /// Examples:
    /// ```zig
    /// const count: ?i64 = try db.queryScalar(i64, "SELECT COUNT(*) FROM users", &.{});
    /// const name: ?[]const u8 = try db.queryScalar(a, []const u8, "SELECT name FROM users WHERE id = ?", &.{...});
    /// defer if (name) |n| a.free(n);
    /// ```
    pub fn queryScalar(
        self: *DB,
        allocator: std.mem.Allocator,
        comptime T: type,
        sql: [:0]const u8,
        params: []const SqlParam,
    ) !?T {
        var result = try self.queryParams(sql, params);
        defer result.deinit();

        if (!result.next()) return null;
        const row = result.currentRow().?;
        return scalarFromCell(T, row.cells[0], allocator);
    }

    /// Convenience variant: `execMany` runs the same prepared statement
    /// once per parameter row. All inserts share a single prepared
    /// statement (driver-side cache reuse coming in v0.19); each row's
    /// params are bound independently.
    ///
    /// Use for batch inserts / updates where each row has a different
    /// parameter set but the same SQL template.
    ///
    /// Example:
    /// ```zig
    /// try db.execMany(
    ///     "INSERT INTO users (name, email) VALUES (?, ?)",
    ///     &.{
    ///         &[_]SqlParam{ .{ .text = "Alice" }, .{ .text = "a@x" } },
    ///         &[_]SqlParam{ .{ .text = "Bob"   }, .{ .text = "b@x" } },
    ///     },
    /// );
    /// ```
    pub fn execMany(
        self: *DB,
        sql: [:0]const u8,
        rows: []const []const SqlParam,
    ) !void {
        for (rows) |params| {
            try self.execParams(sql, params);
        }
    }

    /// Install a server-side prepared statement under `name`. Subsequent
    /// `execCached(name, ...)` / `queryCached(name, ...)` reuse it.
    ///
    /// Naming convention: prefix with your app to avoid collisions with
    /// other clients sharing the same connection (e.g. `"myapp_users_get"`).
    ///
    /// For PG, `n_params` is the number of `?` placeholders. For MySQL,
    /// the parameter count is inferred from `params`.
    pub fn prepareCached(
        self: *DB,
        name: [:0]const u8,
        sql: [:0]const u8,
        n_params: c_int,
    ) !void {
        try self.guard();
        switch (self.driver) {
            .postgres => |*d| {
                if (build_opts.enable_pg) {
                    try d.prepareCached(name, sql, n_params);
                } else return error.DriverNotEnabled;
            },
            .mysql => |*d| {
                if (build_opts.enable_mysql) {
                    try d.prepareCached(name, sql, n_params);
                } else return error.DriverNotEnabled;
            },
            .sqlite => return error.UnsupportedDriver,
        }
    }

    /// Execute a previously-prepared statement.
    ///
    /// For MySQL, `params` are bound via `MYSQL_BIND`. For PG, the
    /// params are converted from `SqlParam` to the c-string format
    /// expected by `PQexecPrepared`.
    pub fn execCached(
        self: *DB,
        name: [:0]const u8,
        params: []const SqlParam,
    ) !void {
        try self.guard();
        switch (self.driver) {
            .postgres => |*d| {
                if (build_opts.enable_pg) {
                    try pgExecCached(d, name, params);
                } else return error.DriverNotEnabled;
            },
            .mysql => |*d| {
                if (build_opts.enable_mysql) {
                    try d.execCached(name, params);
                } else return error.DriverNotEnabled;
            },
            .sqlite => return error.UnsupportedDriver,
        }
    }

    /// DEALLOCATE / close a cached prepared statement. After this,
    /// `name` must be `prepareCached`d again before reuse.
    pub fn releaseCached(self: *DB, name: [:0]const u8) void {
        if (self.magic != 0xDBDBDBDB or !self.valid) return;
        switch (self.driver) {
            .postgres => |*d| if (build_opts.enable_pg) d.releaseCached(name) catch {},
            .mysql => |*d| if (build_opts.enable_mysql) d.releaseCached(name),
            .sqlite => {},
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

/// Configuration for `DB.transaction` deadlock retry behavior.
pub const DeadlockRetry = struct {
    /// Maximum number of additional attempts after the first one fails
    /// with a deadlock-class error. 0 = no retry. 3 = 4 total attempts.
    max_retries: u32 = 3,
};

/// Bridge `DB.execCached` → `PostgresDB.execPrepared` by converting
/// `[]const SqlParam` to the `(values, lengths, formats)` triple
/// `PQexecPrepared` expects. All text/blob buffers are allocated on
/// `allocator` and freed before returning.
fn pgExecCached(
    d: *@import("drivers/postgres.zig").PostgresDB,
    name: [:0]const u8,
    params: []const SqlParam,
) !void {
    var values: []?[*:0]const u8 = &.{};
    var lengths: []c_int = &.{};
    var formats: []c_int = &.{};
    var strings: [][]u8 = &.{};

    if (params.len > 0) {
        values = try d.allocator.alloc(?[*:0]const u8, params.len);
        lengths = try d.allocator.alloc(c_int, params.len);
        formats = try d.allocator.alloc(c_int, params.len);
        strings = try d.allocator.alloc([]u8, params.len);

        for (params, 0..) |p, i| {
            formats[i] = 0;
            switch (p) {
                .null => {
                    values[i] = null;
                    lengths[i] = 0;
                },
                .int => |v| {
                    const s = try std.fmt.allocPrint(d.allocator, "{d}", .{v});
                    const s0 = try d.allocator.alloc(u8, s.len + 1);
                    @memcpy(s0[0..s.len], s);
                    s0[s.len] = 0;
                    d.allocator.free(s);
                    strings[i] = s0;
                    values[i] = @ptrCast(s0.ptr);
                    lengths[i] = 0;
                },
                .real => |v| {
                    const s = try std.fmt.allocPrint(d.allocator, "{d}", .{v});
                    const s0 = try d.allocator.alloc(u8, s.len + 1);
                    @memcpy(s0[0..s.len], s);
                    s0[s.len] = 0;
                    d.allocator.free(s);
                    strings[i] = s0;
                    values[i] = @ptrCast(s0.ptr);
                    lengths[i] = 0;
                },
                .text => |v| {
                    const s0 = try d.allocator.alloc(u8, v.len + 1);
                    @memcpy(s0[0..v.len], v);
                    s0[v.len] = 0;
                    strings[i] = s0;
                    values[i] = @ptrCast(s0.ptr);
                    lengths[i] = 0;
                },
                .blob => |v| {
                    values[i] = @ptrCast(@constCast(v.ptr));
                    lengths[i] = @intCast(v.len);
                    formats[i] = 1;
                },
            }
        }
    }
    defer {
        for (strings) |s| d.allocator.free(s);
        if (params.len > 0) {
            d.allocator.free(values);
            d.allocator.free(lengths);
            d.allocator.free(formats);
            d.allocator.free(strings);
        }
    }

    const res = try d.execCached(name, values, lengths, formats, 0); // 0 = text result
    d.c.PQclear(res);
}

/// Returns true if `err` is a deadlock-style error that may succeed on
/// retry. Matches PG `40P01` (deadlock_detected) and MySQL `1213`
/// (ER_LOCK_DEADLOCK). All other errors are returned as-is.
fn isDeadlockError(err: anyerror) bool {
    return err == error.Deadlock;
}

/// Convert a single `Cell` to a typed scalar. Used by `queryScalar`.
/// Only the types explicitly listed below are supported; passing an
/// unsupported `T` is a compile error.
///
/// For `T = []const u8`, the returned slice is heap-allocated via
/// `allocator` and the caller owns it.
fn scalarFromCell(comptime T: type, cell: Cell, allocator: std.mem.Allocator) ?T {
    return switch (T) {
        i64 => switch (cell) {
            .null => null,
            .int => |v| v,
            .bool => |b| if (b) 1 else 0,
            .float => |v| @intFromFloat(v),
            .text => |t| std.fmt.parseInt(i64, t, 10) catch null,
            .blob => null,
        },
        f64 => switch (cell) {
            .null => null,
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            .bool => |b| if (b) 1.0 else 0.0,
            .text => |t| std.fmt.parseFloat(f64, t) catch null,
            .blob => null,
        },
        bool => switch (cell) {
            .null => null,
            .bool => |b| b,
            .int => |v| v != 0,
            .float => |v| v != 0.0,
            .text => |t| blk: {
                if (std.mem.eql(u8, t, "t") or
                    std.mem.eql(u8, t, "1") or
                    std.mem.eql(u8, t, "true"))
                {
                    break :blk true;
                }
                if (std.mem.eql(u8, t, "f") or
                    std.mem.eql(u8, t, "0") or
                    std.mem.eql(u8, t, "false"))
                {
                    break :blk false;
                }
                break :blk null;
            },
            .blob => null,
        },
        []const u8 => switch (cell) {
            .null => null,
            .text => |t| allocator.dupe(u8, t) catch null,
            .int => |v| blk: {
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return null;
                break :blk allocator.dupe(u8, s) catch null;
            },
            .bool => |b| allocator.dupe(u8, if (b) "true" else "false") catch null,
            .float => |v| blk: {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return null;
                break :blk allocator.dupe(u8, s) catch null;
            },
            .blob => null,
        },
        else => @compileError("queryScalar T must be i64, f64, bool, or []const u8"),
    };
}

test {
    _ = @import("integration_test.zig");
}
