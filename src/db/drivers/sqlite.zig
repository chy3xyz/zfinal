const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const ResultSet = @import("../result.zig").ResultSet;
const SqlParam = @import("../sql_param.zig").SqlParam;

const c = @cImport({
    @cInclude("sqlite3.h");
});

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
        const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{config.database});

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
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("SQLite prepare failed: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        try bindParams(stmt, params);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) {
            std.debug.print("SQLite step failed: {d}\n", .{step_rc});
            return error.StepFailed;
        }

        self.last_changes = c.sqlite3_changes(self.db);
    }

    /// Execute query with parameter binding
    pub fn queryParams(self: *SQLiteDB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("SQLite prepare failed: {s}\n", .{c.sqlite3_errmsg(self.db)});
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
                return error.StepFailed;
            }

            // Read row data
            var cells = try self.allocator.alloc(?[]const u8, @intCast(n_cols));
            errdefer {
                for (cells) |cell| {
                    if (cell) |cval| self.allocator.free(cval);
                }
                self.allocator.free(cells);
            }

            for (0..@intCast(n_cols)) |i| {
                const col_type = c.sqlite3_column_type(stmt, @intCast(i));

                if (col_type == c.SQLITE_NULL) {
                    cells[i] = null;
                } else {
                    const text = c.sqlite3_column_text(stmt, @intCast(i));
                    if (text != null) {
                        const text_len = std.mem.len(text);
                        cells[i] = try self.allocator.dupe(u8, text[0..text_len]);
                    } else {
                        cells[i] = null;
                    }
                }
            }

            try result_set.addRow(cells);
        }

        return result_set;
    }

    /// Legacy query without params (kept for backward compatibility)
    pub fn query(self: *SQLiteDB, sql: [:0]const u8) !ResultSet {
        return self.queryParams(sql, &.{});
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
