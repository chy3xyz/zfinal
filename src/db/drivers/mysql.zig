const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const ResultSet = @import("../result.zig").ResultSet;
const SqlParam = @import("../sql_param.zig").SqlParam;

const c = @import("c_mysql");

pub const MySQLDB = struct {
    conn: ?*c.MYSQL,
    allocator: std.mem.Allocator,
    last_affected: u64 = 0,

    pub fn connect(allocator: std.mem.Allocator, config: DBConfig) !MySQLDB {
        const conn = c.mysql_init(null) orelse return error.InitFailed;

        var h_buf: [256]u8 = undefined;
        var u_buf: [256]u8 = undefined;
        var p_buf: [256]u8 = undefined;
        var d_buf: [256]u8 = undefined;

        const h_slice = try std.fmt.bufPrint(&h_buf, "{s}", .{config.host orelse "localhost"});
        h_buf[h_slice.len] = 0;
        const h: [:0]const u8 = h_buf[0..h_slice.len :0];
        const u_slice = try std.fmt.bufPrint(&u_buf, "{s}", .{config.username orelse "root"});
        u_buf[u_slice.len] = 0;
        const u: [:0]const u8 = u_buf[0..u_slice.len :0];
        const pw_slice = try std.fmt.bufPrint(&p_buf, "{s}", .{config.password orelse ""});
        p_buf[pw_slice.len] = 0;
        const pw: [:0]const u8 = p_buf[0..pw_slice.len :0];
        const db_slice = try std.fmt.bufPrint(&d_buf, "{s}", .{config.database});
        d_buf[db_slice.len] = 0;
        const db: [:0]const u8 = d_buf[0..db_slice.len :0];

        if (c.mysql_real_connect(conn, h.ptr, u.ptr, pw.ptr, db.ptr, config.port orelse 3306, null, 0) == null) {
            @memset(&p_buf, 0);
            const msg = c.mysql_error(conn);
            std.debug.print("MySQL connect failed: {s}\n", .{msg});
            c.mysql_close(conn);
            return error.ConnectionFailed;
        }
        @memset(&p_buf, 0);
        @memset(&u_buf, 0);

        return .{ .conn = conn, .allocator = allocator };
    }

    pub fn close(self: *MySQLDB) void {
        if (self.conn) |cxn| {
            c.mysql_close(cxn);
            self.conn = null;
        }
    }

    pub fn ping(self: *MySQLDB) bool {
        if (self.conn == null) return false;
        return c.mysql_ping(self.conn) == 0;
    }

    pub fn exec(self: *MySQLDB, sql: [:0]const u8) !void {
        if (c.mysql_query(self.conn, sql.ptr) != 0) {
            std.debug.print("MySQL exec failed: {s}\n", .{c.mysql_error(self.conn)});
            return error.ExecFailed;
        }
        self.last_affected = c.mysql_affected_rows(self.conn);
    }

    pub fn execParams(self: *MySQLDB, sql: [:0]const u8, params: []const SqlParam) !void {
        const stmt = c.mysql_stmt_init(self.conn) orelse return error.StmtInitFailed;
        defer _ = c.mysql_stmt_close(stmt);

        if (c.mysql_stmt_prepare(stmt, sql.ptr, sql.len) != 0) {
            std.debug.print("MySQL stmt prepare failed: {s}\n", .{c.mysql_stmt_error(stmt)});
            return error.PrepareFailed;
        }

        var bind = try buildMysqlBind(self.allocator, params);
        defer freeMysqlBind(self.allocator, &bind);

        if (c.mysql_stmt_bind_param(stmt, bind.bind.items.ptr)) {
            std.debug.print("MySQL bind failed: {s}\n", .{c.mysql_stmt_error(stmt)});
            return error.BindFailed;
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            std.debug.print("MySQL stmt execute failed: {s}\n", .{c.mysql_stmt_error(stmt)});
            return error.ExecFailed;
        }

        self.last_affected = c.mysql_stmt_affected_rows(stmt);
    }

    pub fn query(self: *MySQLDB, sql: [:0]const u8) !ResultSet {
        if (c.mysql_query(self.conn, sql.ptr) != 0) {
            std.debug.print("MySQL query failed: {s}\n", .{c.mysql_error(self.conn)});
            return error.QueryFailed;
        }

        const res = c.mysql_store_result(self.conn) orelse {
            // Some queries (e.g. CALL) may return no result set
            return ResultSet.init(self.allocator, &.{});
        };
        defer c.mysql_free_result(res);

        return readResult(self.allocator, res);
    }

    pub fn queryParams(self: *MySQLDB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        const stmt = c.mysql_stmt_init(self.conn) orelse return error.StmtInitFailed;
        defer _ = c.mysql_stmt_close(stmt);

        if (c.mysql_stmt_prepare(stmt, sql.ptr, sql.len) != 0) {
            std.debug.print("MySQL stmt prepare failed: {s}\n", .{c.mysql_stmt_error(stmt)});
            return error.PrepareFailed;
        }

        var bind = try buildMysqlBind(self.allocator, params);
        defer freeMysqlBind(self.allocator, &bind);

        if (c.mysql_stmt_bind_param(stmt, bind.bind.items.ptr)) {
            std.debug.print("MySQL bind failed: {s}\n", .{c.mysql_stmt_error(stmt)});
            return error.BindFailed;
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            std.debug.print("MySQL stmt execute failed: {s}\n", .{c.mysql_stmt_error(stmt)});
            return error.ExecFailed;
        }

        // Fetch result metadata
        const meta = c.mysql_stmt_result_metadata(stmt) orelse {
            return ResultSet.init(self.allocator, &.{});
        };
        defer c.mysql_free_result(meta);

        const n_cols: usize = @intCast(c.mysql_num_fields(meta));
        var columns = try self.allocator.alloc([]const u8, n_cols);
        errdefer self.allocator.free(columns);

        const fields = c.mysql_fetch_fields(meta);
        for (0..n_cols) |i| {
            columns[i] = try self.allocator.dupe(u8, fields[i].name[0..@intCast(fields[i].name_length)]);
        }

        var result_set = ResultSet.init(self.allocator, columns);
        errdefer result_set.deinit();

        // Allocate per-column buffers for text results
        var col_bufs = try self.allocator.alloc([4096]u8, n_cols);
        defer self.allocator.free(col_bufs);
        var col_lengths = try self.allocator.alloc(c_ulong, n_cols);
        defer self.allocator.free(col_lengths);
        var col_is_null = try self.allocator.alloc(bool, n_cols);
        defer self.allocator.free(col_is_null);
        var col_err = try self.allocator.alloc(bool, n_cols);
        defer self.allocator.free(col_err);

        // Build MYSQL_BIND output array
        var out_bind = try self.allocator.alloc(c.MYSQL_BIND, n_cols);
        defer self.allocator.free(out_bind);
        for (0..n_cols) |i| {
            out_bind[i] = .{
                .buffer_type = c.MYSQL_TYPE_STRING,
                .buffer = &col_bufs[i],
                .buffer_length = 4096,
                .length = &col_lengths[i],
                .is_null = &col_is_null[i],
                .@"error" = &col_err[i],
            };
        }
        if (c.mysql_stmt_bind_result(stmt, out_bind.ptr)) {
            return error.BindFailed;
        }

        // Fetch rows
        while (true) {
            const rc = c.mysql_stmt_fetch(stmt);
            if (rc == c.MYSQL_NO_DATA) break;
            if (rc == c.MYSQL_DATA_TRUNCATED) {} // continue
            if (rc != 0 and rc != c.MYSQL_DATA_TRUNCATED) {
                std.debug.print("MySQL fetch failed: {s}\n", .{c.mysql_stmt_error(stmt)});
                return error.FetchFailed;
            }

            var cells = try self.allocator.alloc(?[]const u8, n_cols);
            errdefer {
                for (cells) |c_| if (c_) |v| self.allocator.free(v);
                self.allocator.free(cells);
            }
            for (0..n_cols) |i| {
                if (col_is_null[i]) {
                    cells[i] = null;
                } else {
                    cells[i] = try self.allocator.dupe(u8, col_bufs[i][0..@intCast(col_lengths[i])]);
                }
            }
            try result_set.addRow(cells);
        }

        return result_set;
    }

    pub fn lastInsertId(self: *MySQLDB) i64 {
        return @intCast(c.mysql_insert_id(self.conn));
    }

    pub fn affectedRows(self: *MySQLDB) i64 {
        return @intCast(self.last_affected);
    }

    const MysqlBindData = struct {
        bind: std.ArrayList(c.MYSQL_BIND),
        ints: std.ArrayList(i64),
        reals: std.ArrayList(f64),
        strings: std.ArrayList([]const u8),
        lengths: std.ArrayList(c_ulong),
        is_nulls: std.ArrayList(bool),
    };

    fn buildMysqlBind(allocator: std.mem.Allocator, params: []const SqlParam) !MysqlBindData {
        var data = MysqlBindData{
            .bind = std.ArrayList(c.MYSQL_BIND).empty,
            .ints = std.ArrayList(i64).empty,
            .reals = std.ArrayList(f64).empty,
            .strings = std.ArrayList([]const u8).empty,
            .lengths = std.ArrayList(c_ulong).empty,
            .is_nulls = std.ArrayList(bool).empty,
        };

        // Pre-allocate all ArrayLists to prevent reallocation during the loop.
        // MYSQL_BIND stores pointers into the other ArrayLists — reallocation
        // would invalidate those pointers, causing segfault in mysql_stmt_bind_param.
        const n = params.len;
        try data.bind.ensureTotalCapacity(allocator, n);
        try data.ints.ensureTotalCapacity(allocator, n);
        try data.reals.ensureTotalCapacity(allocator, n);
        try data.strings.ensureTotalCapacity(allocator, n);
        try data.lengths.ensureTotalCapacity(allocator, n);
        try data.is_nulls.ensureTotalCapacity(allocator, n);

        for (params) |p| {
            switch (p) {
                .null => {
                    data.is_nulls.appendAssumeCapacity(true);
                    data.ints.appendAssumeCapacity(0);
                    data.reals.appendAssumeCapacity(0);
                    data.strings.appendAssumeCapacity("");
                    data.lengths.appendAssumeCapacity(0);
                    data.bind.appendAssumeCapacity(.{
                        .buffer_type = c.MYSQL_TYPE_NULL,
                        .buffer = @ptrCast(@constCast(&data.ints.items[data.ints.items.len - 1])),
                        .buffer_length = 8,
                        .is_null = &data.is_nulls.items[data.is_nulls.items.len - 1],
                        .length = &data.lengths.items[data.lengths.items.len - 1],
                    });
                },
                .int => |v| {
                    data.is_nulls.appendAssumeCapacity(false);
                    data.ints.appendAssumeCapacity(v);
                    data.reals.appendAssumeCapacity(0);
                    data.strings.appendAssumeCapacity("");
                    data.lengths.appendAssumeCapacity(0);
                    data.bind.appendAssumeCapacity(.{
                        .buffer_type = c.MYSQL_TYPE_LONGLONG,
                        .buffer = @ptrCast(@constCast(&data.ints.items[data.ints.items.len - 1])),
                        .buffer_length = 8,
                        .is_null = &data.is_nulls.items[data.is_nulls.items.len - 1],
                        .length = &data.lengths.items[data.lengths.items.len - 1],
                    });
                },
                .real => |v| {
                    data.is_nulls.appendAssumeCapacity(false);
                    data.ints.appendAssumeCapacity(0);
                    data.reals.appendAssumeCapacity(v);
                    data.strings.appendAssumeCapacity("");
                    data.lengths.appendAssumeCapacity(0);
                    data.bind.appendAssumeCapacity(.{
                        .buffer_type = c.MYSQL_TYPE_DOUBLE,
                        .buffer = @ptrCast(@constCast(&data.reals.items[data.reals.items.len - 1])),
                        .buffer_length = 8,
                        .is_null = &data.is_nulls.items[data.is_nulls.items.len - 1],
                        .length = &data.lengths.items[data.lengths.items.len - 1],
                    });
                },
                .text, .blob => |v| {
                    data.is_nulls.appendAssumeCapacity(false);
                    data.ints.appendAssumeCapacity(0);
                    data.reals.appendAssumeCapacity(0);
                    data.strings.appendAssumeCapacity(v);
                    data.lengths.appendAssumeCapacity(@intCast(v.len));
                    data.bind.appendAssumeCapacity(.{
                        .buffer_type = c.MYSQL_TYPE_STRING,
                        .buffer = @ptrCast(@constCast(v.ptr)),
                        .buffer_length = @intCast(v.len),
                        .is_null = &data.is_nulls.items[data.is_nulls.items.len - 1],
                        .length = &data.lengths.items[data.lengths.items.len - 1],
                    });
                },
            }
        }
        return data;
    }

    fn freeMysqlBind(allocator: std.mem.Allocator, data: *MysqlBindData) void {
        data.strings.deinit(allocator);
        data.ints.deinit(allocator);
        data.reals.deinit(allocator);
        data.lengths.deinit(allocator);
        data.is_nulls.deinit(allocator);
        data.bind.deinit(allocator);
    }

    fn readResult(allocator: std.mem.Allocator, res: *c.MYSQL_RES) !ResultSet {
        const n_cols: usize = @intCast(c.mysql_num_fields(res));
        var columns = try allocator.alloc([]const u8, n_cols);
        errdefer allocator.free(columns);

        const fields = c.mysql_fetch_fields(res);
        for (0..n_cols) |i| {
            columns[i] = try allocator.dupe(u8, fields[i].name[0..@intCast(fields[i].name_length)]);
        }

        var result_set = ResultSet.init(allocator, columns);
        errdefer result_set.deinit();

        while (true) {
            const row = c.mysql_fetch_row(res) orelse break;
            const lengths = c.mysql_fetch_lengths(res);

            var cells = try allocator.alloc(?[]const u8, n_cols);
            errdefer {
                for (cells) |c_| if (c_) |v| allocator.free(v);
                allocator.free(cells);
            }
            for (0..n_cols) |i| {
                if (row[i] == null) {
                    cells[i] = null;
                } else {
                    const len: usize = @intCast(lengths[i]);
                    cells[i] = try allocator.dupe(u8, row[i][0..len]);
                }
            }
            try result_set.addRow(cells);
        }

        return result_set;
    }
};
