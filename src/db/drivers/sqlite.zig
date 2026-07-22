const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const Cell = @import("../result.zig").Cell;
const Row = @import("../result.zig").Row;
const ResultSet = @import("../result.zig").ResultSet;
const SqlParam = @import("../sql_param.zig").SqlParam;

const c = @import("c_sqlite3");

/// SQLite database driver with prepared statement support
pub const SQLiteDB = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,
    last_changes: i32 = 0,

    /// Open SQLite database
    pub fn open(allocator: std.mem.Allocator, config: DBConfig) !SQLiteDB {
        var db: ?*c.sqlite3 = null;

        // Convert to null-terminated string
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}", .{config.database});
        path_buf[path.len] = 0;
        const path_z: [:0]const u8 = path_buf[0..path.len :0];

        const rc = c.sqlite3_open(path_z.ptr, &db);
        if (rc != c.SQLITE_OK) {
            std.debug.print("SQLite open failed. rc={d} err={s} path={s}\n", .{ rc, c.sqlite3_errmsg(db), path_z.ptr });
            if (db) |d| _ = c.sqlite3_close(d);
            return error.DatabaseOpenFailed;
        }

        return SQLiteDB{
            .db = db,
            .allocator = allocator,
        };
    }

    /// Close database
    pub fn close(self: *SQLiteDB) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    /// Health check: returns true if the database handle is alive and responsive.
    pub fn ping(self: *SQLiteDB) bool {
        if (self.db == null) return false;
        // sqlite3_db_readonly returns 0 if the db is read-write, 1 if read-only, -1 if not a db
        const rc = c.sqlite3_db_readonly(self.db, null);
        return rc >= 0;
    }

    /// Execute SQL statement (legacy, prefer execParams)
    pub fn exec(self: *SQLiteDB, sql: [:0]const u8) !void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, &errmsg);
        defer if (errmsg != null) c.sqlite3_free(errmsg);

        if (rc != c.SQLITE_OK) {
            if (errmsg != null) {
                std.debug.print("SQLite exec failed: {s}\n", .{errmsg});
            }
            return error.ExecFailed;
        }

        self.last_changes = c.sqlite3_changes(self.db);
    }

    /// Execute with parameter binding (safe against SQL injection)
    pub fn execParams(self: *SQLiteDB, sql: [:0]const u8, params: []const SqlParam) !void {
        const db = self.db orelse return error.NotConnected;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("SQLite prepare failed: {s}\n", .{c.sqlite3_errmsg(db)});
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        try bindParams(stmt, params);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) {
            const diag = translateStepError(db, step_rc);
            std.debug.print("SQLite step failed: {s} (code {d})\n", .{ diag.message, step_rc });
            return diag.error_code;
        }

        self.last_changes = c.sqlite3_changes(db);
    }

    /// Execute query with parameter binding
    pub fn queryParams(self: *SQLiteDB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        const db = self.db orelse return error.NotConnected;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("SQLite prepare failed: {s}\n", .{c.sqlite3_errmsg(db)});
            return error.PrepareFailed;
        }
        // Note: stmt is consumed by result set for lazy iteration, but here we eagerly fetch
        defer _ = c.sqlite3_finalize(stmt);

        try bindParams(stmt, params);

        // Get column count
        const n_cols = c.sqlite3_column_count(stmt);
        var columns = try self.allocator.alloc([]const u8, @intCast(n_cols));
        errdefer self.allocator.free(columns);

        for (0..@intCast(n_cols)) |i| {
            const col_name = c.sqlite3_column_name(stmt, @intCast(i));
            const col_name_len = std.mem.len(col_name);
            columns[i] = try self.allocator.dupe(u8, col_name[0..col_name_len]);
        }

        var result_set = ResultSet.init(self.allocator, columns);
        errdefer result_set.deinit();

        // Iterate through rows
        while (true) {
            const step_rc = c.sqlite3_step(stmt);

            if (step_rc == c.SQLITE_DONE) {
                break;
            }

            if (step_rc != c.SQLITE_ROW) {
                const diag = translateStepError(db, step_rc);
                std.debug.print("SQLite step failed during query: {s} (code {d})\n", .{ diag.message, step_rc });
                return diag.error_code;
            }

            // Read row data — typed Cell union. SQLite exposes typed columns
            // natively via sqlite3_column_type + sqlite3_column_int64/float/text/blob,
            // so we map each column to its natural Cell variant and avoid the
            // parseInt/parseFloat round-trip on consumer reads.
            var cells = try self.allocator.alloc(Cell, @intCast(n_cols));
            errdefer {
                for (cells) |cell| switch (cell) {
                    .text => |t| self.allocator.free(t),
                    .blob => |b| self.allocator.free(b),
                    else => {},
                };
                self.allocator.free(cells);
            }

            for (0..@intCast(n_cols)) |i| {
                cells[i] = try readSqliteCell(self.allocator, stmt.?, i);
            }

            try result_set.addRow(cells);
        }

        return result_set;
    }

    /// Legacy query without params (kept for backward compatibility)
    pub fn query(self: *SQLiteDB, sql: [:0]const u8) !ResultSet {
        return self.queryParams(sql, &.{});
    }

    /// Open an incremental query iterator. Unlike `queryParams` which
    /// materializes the entire result set into RAM, this yields one Row
    /// at a time via `sqlite3_step`. Memory usage is O(1) per row.
    ///
    /// Caller MUST call `iter.deinit()` to finalize the prepared statement
    /// and free the column-name allocations, even if iteration is aborted
    /// mid-stream.
    pub fn queryIter(self: *SQLiteDB, sql: [:0]const u8, params: []const SqlParam) !SQLiteIter {
        const db = self.db orelse return error.NotConnected;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("SQLite prepare failed: {s}\n", .{c.sqlite3_errmsg(db)});
            return error.PrepareFailed;
        }
        try bindParams(stmt, params);

        const n_cols: usize = @intCast(c.sqlite3_column_count(stmt));
        var columns = try self.allocator.alloc([]const u8, n_cols);
        errdefer self.allocator.free(columns);

        for (0..n_cols) |i| {
            const col_name = c.sqlite3_column_name(stmt, @intCast(i));
            const col_name_len = std.mem.len(col_name);
            columns[i] = try self.allocator.dupe(u8, col_name[0..col_name_len]);
        }

        return .{
            .stmt = stmt,
            .n_cols = n_cols,
            .col_names = columns,
            .allocator = self.allocator,
            .done = false,
        };
    }

    /// Legacy single-arg iterator. Same as `queryIter(sql, &.{})`.
    pub fn queryIterNoArgs(self: *SQLiteDB, sql: [:0]const u8) !SQLiteIter {
        return self.queryIter(sql, &.{});
    }

    /// Incremental query iterator. Holds the prepared statement open and
    /// yields rows one at a time. Always call `deinit()` when done.
    pub const SQLiteIter = struct {
        stmt: ?*c.sqlite3_stmt,
        n_cols: usize,
        col_names: [][]const u8,
        allocator: std.mem.Allocator,
        done: bool,

        /// Fetch the next row. Returns null when iteration completes.
        /// On error the iterator is poisoned; caller should still call deinit.
        pub fn next(self: *SQLiteIter) !?Row {
            if (self.done) return null;
            const stmt = self.stmt orelse return null;
            const step_rc = c.sqlite3_step(stmt);

            if (step_rc == c.SQLITE_DONE) {
                self.done = true;
                return null;
            }
            if (step_rc != c.SQLITE_ROW) {
                const err_msg = c.sqlite3_errmsg(c.sqlite3_db_handle(stmt));
                std.debug.print("SQLite step failed during iter: {s} (code {d})\n", .{ err_msg, step_rc });
                return error.QueryFailed;
            }

            var cells = try self.allocator.alloc(Cell, self.n_cols);
            errdefer {
                for (cells) |cell| switch (cell) {
                    .text => |t| self.allocator.free(t),
                    .blob => |b| self.allocator.free(b),
                    else => {},
                };
                self.allocator.free(cells);
            }
            for (0..self.n_cols) |i| {
                cells[i] = try readSqliteCell(self.allocator, stmt, @intCast(i));
            }
            return Row{ .cells = cells, .allocator = self.allocator };
        }

        pub fn columns(self: *const SQLiteIter) []const []const u8 {
            return self.col_names;
        }

        pub fn deinit(self: *SQLiteIter) void {
            if (self.stmt) |s| {
                _ = c.sqlite3_finalize(s);
                self.stmt = null;
            }
            for (self.col_names) |col| self.allocator.free(col);
            self.allocator.free(self.col_names);
        }
    };

    /// Build a single typed Cell from the current row of a prepared
    /// statement. Shared between the eager `queryParams` and the
    /// incremental `SQLiteIter.next` paths.
    fn readSqliteCell(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: usize) !Cell {
        const col_type = c.sqlite3_column_type(stmt, @intCast(col));
        return switch (col_type) {
            c.SQLITE_NULL => .null,
            c.SQLITE_INTEGER => .{ .int = c.sqlite3_column_int64(stmt, @intCast(col)) },
            c.SQLITE_FLOAT => .{ .float = c.sqlite3_column_double(stmt, @intCast(col)) },
            c.SQLITE_TEXT => blk: {
                const text = c.sqlite3_column_text(stmt, @intCast(col)) orelse break :blk Cell{ .null = {} };
                const text_len = std.mem.len(text);
                break :blk .{ .text = try allocator.dupe(u8, text[0..text_len]) };
            },
            c.SQLITE_BLOB => blk: {
                const blob = c.sqlite3_column_blob(stmt, @intCast(col)) orelse break :blk Cell{ .null = {} };
                const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, @intCast(col)));
                break :blk .{ .blob = try allocator.dupe(u8, @as([*]const u8, @ptrCast(blob))[0..blob_len]) };
            },
            else => .null,
        };
    }

    /// Get last insert rowid
    pub fn lastInsertId(self: *SQLiteDB) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }

    /// Get number of affected rows
    pub fn affectedRows(self: *SQLiteDB) i64 {
        return self.last_changes;
    }

    fn bindParams(stmt: ?*c.sqlite3_stmt, params: []const SqlParam) !void {
        for (params, 1..) |param, idx| {
            const rc = switch (param) {
                .int => |v| c.sqlite3_bind_int64(stmt, @intCast(idx), v),
                .real => |v| c.sqlite3_bind_double(stmt, @intCast(idx), v),
                .text => |v| c.sqlite3_bind_text(stmt, @intCast(idx), v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                .blob => |v| c.sqlite3_bind_blob(stmt, @intCast(idx), v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                .null => c.sqlite3_bind_null(stmt, @intCast(idx)),
            };
            if (rc != c.SQLITE_OK) {
                return error.BindFailed;
            }
        }
    }
};

/// Diagnostic info for a SQLite step error. Designed to be
/// machine-readable so AI agents can show "users.email already
/// exists" instead of "SQLite step failed: 19".
pub const StepDiagnostic = struct {
    code: i32,
    message: []const u8,
    constraint: ?[]const u8 = null,
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
    error_code: anyerror = error.StepFailed,
};

/// Translate a SQLite step return code into a structured diagnostic.
/// Uses sqlite3_extended_errcode + sqlite3_errmsg for context, plus
/// sqlite3_expanded_sql for the actual SQL that failed.
pub fn translateStepError(db: *c.sqlite3, step_rc: c_int) StepDiagnostic {
    const err_code = c.sqlite3_extended_errcode(db);
    const err_msg_c = c.sqlite3_errmsg(db);
    const err_msg: []const u8 = if (err_msg_c) |p| std.mem.sliceTo(p, 0) else "unknown";

    var diag = StepDiagnostic{
        .code = @intCast(step_rc),
        .message = err_msg,
    };

    // Map common constraint violations to specific errors so callers
    // can pattern-match without parsing strings.
    switch (err_code) {
        c.SQLITE_CONSTRAINT_PRIMARYKEY => {
            diag.error_code = error.DuplicatePrimaryKey;
            diag.constraint = "PRIMARY KEY";
        },
        c.SQLITE_CONSTRAINT_UNIQUE => {
            diag.error_code = error.UniqueViolation;
            diag.constraint = "UNIQUE";
            // Try to extract table/column from message "UNIQUE constraint failed: users.email"
            if (std.mem.indexOf(u8, err_msg, ":")) |colon| {
                const after = std.mem.trim(u8, err_msg[colon + 1 ..], " ");
                if (std.mem.indexOfScalar(u8, after, '.')) |dot| {
                    diag.table = after[0..dot];
                    diag.column = after[dot + 1 ..];
                } else {
                    diag.table = after;
                }
            }
        },
        c.SQLITE_CONSTRAINT_NOTNULL => {
            diag.error_code = error.NotNullViolation;
            diag.constraint = "NOT NULL";
            if (std.mem.indexOf(u8, err_msg, ":")) |colon| {
                const after = std.mem.trim(u8, err_msg[colon + 1 ..], " ");
                if (std.mem.indexOfScalar(u8, after, '.')) |dot| {
                    diag.table = after[0..dot];
                    diag.column = after[dot + 1 ..];
                }
            }
        },
        c.SQLITE_CONSTRAINT_FOREIGNKEY => {
            diag.error_code = error.ForeignKeyViolation;
            diag.constraint = "FOREIGN KEY";
        },
        c.SQLITE_CONSTRAINT_CHECK => {
            diag.error_code = error.CheckViolation;
            diag.constraint = "CHECK";
        },
        else => {},
    }

    return diag;
}
