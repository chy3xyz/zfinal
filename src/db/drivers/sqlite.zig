const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const ResultSet = @import("../result.zig").ResultSet;

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// SQLite database driver
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

    /// Execute SQL statement
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

    /// Execute query and return result set
    pub fn query(self: *SQLiteDB, sql: [:0]const u8) !ResultSet {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Get column count
        const n_cols = c.sqlite3_column_count(stmt);
        var columns = try self.allocator.alloc([]const u8, @intCast(n_cols));

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

    /// Get last insert rowid
    pub fn lastInsertId(self: *SQLiteDB) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }

    /// Get number of affected rows
    pub fn affectedRows(self: *SQLiteDB) i64 {
        return self.last_changes;
    }
};
