const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const Cell = @import("../result.zig").Cell;
const Row = @import("../result.zig").Row;
const ResultSet = @import("../result.zig").ResultSet;
const SqlParam = @import("../sql_param.zig").SqlParam;
const diag = @import("../diag.zig");

const c = @import("c_mysql");

const DEFAULT_BINLOG_SERVER_ID = 0x7a65746c; // "zetl"

// mysql_ssl_mode enum values from <mysql.h>. Match the enum's numeric
// ordering — DO NOT reorder. We use the C-side enum tag directly when
// passing to mysql_options().
const SSL_MODE_DISABLED: c_int = 1;
const SSL_MODE_PREFERRED: c_int = 2;
const SSL_MODE_REQUIRED: c_int = 3;
const SSL_MODE_VERIFY_CA: c_int = 4;
const SSL_MODE_VERIFY_IDENTITY: c_int = 5;

pub const MySQLDB = struct {
    conn: ?*c.MYSQL,
    allocator: std.mem.Allocator,
    last_affected: u64 = 0,
    rpl: ?c.MYSQL_RPL = null,
    binlog_opened: bool = false,

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

        // Set connect timeout BEFORE mysql_real_connect. mysql_options returns
        // 0 on success and a non-zero errno on failure.
        const timeout_sec: c_uint = @intCast(config.timeout);
        if (c.mysql_options(conn, c.MYSQL_OPT_CONNECT_TIMEOUT, &timeout_sec) != 0) {
            const msg = c.mysql_error(conn);
            std.debug.print("MySQL set connect_timeout failed: {s}\n", .{msg});
            c.mysql_close(conn);
            return error.InitFailed;
        }

        // Set SSL mode. cloud DBs default to REQUIRED; explicit DISABLED
        // avoids the 5s handshake timeout on localhost dev.
        const ssl_int: c_int = switch (config.ssl_mode) {
            .disable => SSL_MODE_DISABLED,
            .prefer => SSL_MODE_PREFERRED, // PREFERRED = "use if available, fallback to plaintext"
            .require => SSL_MODE_REQUIRED,
            .verify_ca => SSL_MODE_VERIFY_CA,
            .verify_full => SSL_MODE_VERIFY_IDENTITY,
        };
        if (c.mysql_options(conn, c.MYSQL_OPT_SSL_MODE, &ssl_int) != 0) {
            const msg = c.mysql_error(conn);
            std.debug.print("MySQL set SSL mode failed: {s}\n", .{msg});
            c.mysql_close(conn);
            return error.InitFailed;
        }

        // When unix_socket is set, pass the path as the 7th argument to
        // mysql_real_connect. libmysqlclient detects the SOCKET protocol
        // automatically when unix_socket is non-null and host is "localhost".
        // For unix sockets the port argument is ignored — pass 0.
        const sock_ptr = if (config.unix_socket) |sock| sock.ptr else null;
        const port_arg: c_uint = if (config.unix_socket == null) (config.port orelse 3306) else 0;

        if (c.mysql_real_connect(conn, h.ptr, u.ptr, pw.ptr, db.ptr, port_arg, sock_ptr, 0) == null) {
            @memset(&p_buf, 0);
            const msg = c.mysql_error(conn);
            std.debug.print("MySQL connect failed: {s}\n", .{msg});
            c.mysql_close(conn);
            return error.ConnectionFailed;
        }

        // Force utf8mb4 client charset for full Unicode + emoji round-trip.
        // The server may default to latin1 or utf8 (3-byte BMP only).
        if (c.mysql_set_character_set(conn, "utf8mb4") != 0) {
            const msg = c.mysql_error(conn);
            std.debug.print("MySQL set utf8mb4 failed: {s}\n", .{msg});
            c.mysql_close(conn);
            return error.InitFailed;
        }

        @memset(&p_buf, 0);
        @memset(&u_buf, 0);

        return .{ .conn = conn, .allocator = allocator };
    }

    pub fn close(self: *MySQLDB) void {
        self.binlogClose();
        if (self.conn) |cxn| {
            c.mysql_close(cxn);
            self.conn = null;
        }
    }

    pub fn ping(self: *MySQLDB) bool {
        const cxn = self.conn orelse return false;
        if (@intFromPtr(cxn) >= 0xaaaaaaaaaaaaaaaa) return false;
        return c.mysql_ping(cxn) == 0;
    }

    pub fn exec(self: *MySQLDB, sql: [:0]const u8) !void {
        const cxn = self.conn orelse return error.ConnectionFailed;
        if (c.mysql_query(cxn, sql.ptr) != 0) {
            const d = extractMysqlDiag(cxn);
            std.debug.print("MySQL exec failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }
        self.last_affected = c.mysql_affected_rows(cxn);
    }

    pub fn execParams(self: *MySQLDB, sql: [:0]const u8, params: []const SqlParam) !void {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const stmt = c.mysql_stmt_init(cxn) orelse return error.StmtInitFailed;
        defer _ = c.mysql_stmt_close(stmt);

        if (c.mysql_stmt_prepare(stmt, sql.ptr, sql.len) != 0) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL stmt prepare failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        var bind = try buildMysqlBind(self.allocator, params);
        defer freeMysqlBind(self.allocator, &bind);

        if (c.mysql_stmt_bind_param(stmt, bind.bind.items.ptr)) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL bind failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL stmt execute failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        self.last_affected = c.mysql_stmt_affected_rows(stmt);
    }

    pub fn query(self: *MySQLDB, sql: [:0]const u8) !ResultSet {
        const cxn = self.conn orelse return error.ConnectionFailed;
        if (c.mysql_query(cxn, sql.ptr) != 0) {
            const d = extractMysqlDiag(cxn);
            std.debug.print("MySQL query failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        const res = c.mysql_store_result(cxn) orelse {
            // Some queries (e.g. CALL) may return no result set
            return ResultSet.init(self.allocator, &.{});
        };
        defer c.mysql_free_result(res);

        return readResult(self.allocator, res);
    }

    pub fn queryParams(self: *MySQLDB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const stmt = c.mysql_stmt_init(cxn) orelse return error.StmtInitFailed;
        defer _ = c.mysql_stmt_close(stmt);

        if (c.mysql_stmt_prepare(stmt, sql.ptr, sql.len) != 0) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL stmt prepare failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        var bind = try buildMysqlBind(self.allocator, params);
        defer freeMysqlBind(self.allocator, &bind);

        if (c.mysql_stmt_bind_param(stmt, bind.bind.items.ptr)) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL bind failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL stmt execute failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
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

        // Build one ColumnBuf per output column with the matching MYSQL_BIND
        // buffer_type. Numeric columns ask for LONGLONG/DOUBLE binary; text
        // columns ask for STRING with a 4096-byte buffer (truncation is
        // surfaced via MYSQL_DATA_TRUNCATED for callers that need it).
        var col_bufs = try self.allocator.alloc(ColumnBuf, n_cols);
        defer self.allocator.free(col_bufs);

        for (0..n_cols) |i| {
            const ft = fields[i].type;
            col_bufs[i] = ColumnBuf{};
            col_bufs[i].bind.buffer_type = mysqlBindType(ft);
            col_bufs[i].bind.is_null = &col_bufs[i].is_null;
            col_bufs[i].bind.@"error" = &col_bufs[i].is_err;
            col_bufs[i].bind.length = &col_bufs[i].length;

            switch (col_bufs[i].bind.buffer_type) {
                c.MYSQL_TYPE_LONGLONG => {
                    col_bufs[i].bind.buffer = &col_bufs[i].int_buf;
                    col_bufs[i].bind.buffer_length = 8;
                },
                c.MYSQL_TYPE_DOUBLE => {
                    col_bufs[i].bind.buffer = &col_bufs[i].float_buf;
                    col_bufs[i].bind.buffer_length = 8;
                },
                c.MYSQL_TYPE_NULL => {
                    col_bufs[i].bind.buffer = null;
                    col_bufs[i].bind.buffer_length = 0;
                },
                else => {
                    // STRING / BLOB / DATE etc. — text path
                    col_bufs[i].bind.buffer = &col_bufs[i].text_buf;
                    col_bufs[i].bind.buffer_length = col_bufs[i].text_buf.len;
                },
            }
        }

        // Slice of MYSQL_BIND for mysql_stmt_bind_result. Same lifetime as col_bufs.
        var bind_slice = try self.allocator.alloc(c.MYSQL_BIND, n_cols);
        defer self.allocator.free(bind_slice);
        for (0..n_cols) |i| {
            bind_slice[i] = col_bufs[i].bind;
        }
        if (c.mysql_stmt_bind_result(stmt, bind_slice.ptr)) {
            return error.BindFailed;
        }

        // Fetch rows
        while (true) {
            const rc = c.mysql_stmt_fetch(stmt);
            if (rc == c.MYSQL_NO_DATA) break;
            if (rc == c.MYSQL_DATA_TRUNCATED) {} // continue (TEXT/BLOB truncation noted, not fatal)
            if (rc != 0 and rc != c.MYSQL_DATA_TRUNCATED) {
                const d = extractMysqlStmtDiag(stmt);
                std.debug.print("MySQL fetch failed [errno {s}]: {s}\n", .{ d.raw, d.message });
                return diag.toError(d.code);
            }

            var cells = try self.allocator.alloc(Cell, n_cols);
            errdefer {
                for (cells) |cell| switch (cell) {
                    .text => |t| self.allocator.free(t),
                    .blob => |b| self.allocator.free(b),
                    else => {},
                };
                self.allocator.free(cells);
            }
            for (0..n_cols) |i| {
                cells[i] = try readMysqlCell(self.allocator, &col_bufs[i]);
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

    /// Open an incremental query iterator. Like `queryParams`, but yields
    /// one row at a time via `mysql_stmt_fetch` instead of materializing
    /// the entire result set. Memory is O(1) per row.
    ///
    /// Caller MUST call `iter.deinit()` to close the prepared statement
    /// and free the column-name + column-buffer allocations, even if
    /// iteration is aborted mid-stream.
    pub fn queryIter(self: *MySQLDB, sql: [:0]const u8, params: []const SqlParam) !MySQLIter {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const stmt = c.mysql_stmt_init(cxn) orelse return error.StmtInitFailed;

        if (c.mysql_stmt_prepare(stmt, sql.ptr, sql.len) != 0) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL stmt prepare failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            _ = c.mysql_stmt_close(stmt);
            return diag.toError(d.code);
        }

        var bind = try buildMysqlBind(self.allocator, params);
        defer freeMysqlBind(self.allocator, &bind);

        if (c.mysql_stmt_bind_param(stmt, bind.bind.items.ptr)) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL bind failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            _ = c.mysql_stmt_close(stmt);
            return diag.toError(d.code);
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            const d = extractMysqlStmtDiag(stmt);
            std.debug.print("MySQL stmt execute failed [errno {s}]: {s}\n", .{ d.raw, d.message });
            _ = c.mysql_stmt_close(stmt);
            return diag.toError(d.code);
        }

        const meta = c.mysql_stmt_result_metadata(stmt);
        if (meta == null) {
            // No result set (e.g. CALL returning no data). Return an empty iterator.
            return .{
                .stmt = stmt,
                .n_cols = 0,
                .col_names = &.{},
                .col_bufs = &.{},
                .bind_slice = &.{},
                .allocator = self.allocator,
                .done = true,
            };
        }
        // Per-iterator we own the meta + col_names + col_bufs + bind_slice.
        // Finalize meta in deinit (or after binding — libmysql allows this).
        defer c.mysql_free_result(meta);

        const n_cols: usize = @intCast(c.mysql_num_fields(meta));
        const fields = c.mysql_fetch_fields(meta);

        var col_names = try self.allocator.alloc([]const u8, n_cols);
        errdefer {
            for (col_names) |n| if (n.len > 0) self.allocator.free(n);
            self.allocator.free(col_names);
        }
        for (0..n_cols) |i| {
            col_names[i] = try self.allocator.dupe(u8, fields[i].name[0..@intCast(fields[i].name_length)]);
        }

        var col_bufs = try self.allocator.alloc(ColumnBuf, n_cols);
        errdefer self.allocator.free(col_bufs);

        for (0..n_cols) |i| {
            const ft = fields[i].type;
            col_bufs[i] = ColumnBuf{};
            col_bufs[i].bind.buffer_type = mysqlBindType(ft);
            col_bufs[i].bind.is_null = &col_bufs[i].is_null;
            col_bufs[i].bind.@"error" = &col_bufs[i].is_err;
            col_bufs[i].bind.length = &col_bufs[i].length;
            switch (col_bufs[i].bind.buffer_type) {
                c.MYSQL_TYPE_LONGLONG => {
                    col_bufs[i].bind.buffer = &col_bufs[i].int_buf;
                    col_bufs[i].bind.buffer_length = 8;
                },
                c.MYSQL_TYPE_DOUBLE => {
                    col_bufs[i].bind.buffer = &col_bufs[i].float_buf;
                    col_bufs[i].bind.buffer_length = 8;
                },
                c.MYSQL_TYPE_NULL => {
                    col_bufs[i].bind.buffer = null;
                    col_bufs[i].bind.buffer_length = 0;
                },
                else => {
                    col_bufs[i].bind.buffer = &col_bufs[i].text_buf;
                    col_bufs[i].bind.buffer_length = col_bufs[i].text_buf.len;
                },
            }
        }

        var bind_slice = try self.allocator.alloc(c.MYSQL_BIND, n_cols);
        errdefer self.allocator.free(bind_slice);
        for (0..n_cols) |i| bind_slice[i] = col_bufs[i].bind;
        if (c.mysql_stmt_bind_result(stmt, bind_slice.ptr)) {
            return error.BindFailed;
        }

        return .{
            .stmt = stmt,
            .n_cols = n_cols,
            .col_names = col_names,
            .col_bufs = col_bufs,
            .bind_slice = bind_slice,
            .allocator = self.allocator,
            .done = false,
        };
    }

    /// Incremental query iterator. Holds the prepared statement + per-column
    /// buffers open and yields rows one at a time via `mysql_stmt_fetch`.
    /// Always call `deinit()` to free resources.
    pub const MySQLIter = struct {
        stmt: ?*c.MYSQL_STMT,
        n_cols: usize,
        col_names: [][]const u8,
        col_bufs: []ColumnBuf,
        bind_slice: []c.MYSQL_BIND,
        allocator: std.mem.Allocator,
        done: bool,

        /// Fetch the next row. Returns null when iteration completes.
        /// On error the iterator is poisoned — caller should still deinit.
        pub fn next(self: *MySQLIter) !?Row {
            if (self.done) return null;
            const stmt = self.stmt orelse {
                self.done = true;
                return null;
            };
            const rc = c.mysql_stmt_fetch(stmt);
            if (rc == c.MYSQL_NO_DATA) {
                self.done = true;
                return null;
            }
            if (rc != 0 and rc != c.MYSQL_DATA_TRUNCATED) {
                const d = extractMysqlStmtDiag(stmt);
                std.debug.print("MySQL iter fetch failed [errno {s}]: {s}\n", .{ d.raw, d.message });
                return diag.toError(d.code);
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
                cells[i] = try readMysqlCell(self.allocator, &self.col_bufs[i]);
            }
            return Row{ .cells = cells, .allocator = self.allocator };
        }

        pub fn columns(self: *const MySQLIter) []const []const u8 {
            return self.col_names;
        }

        pub fn deinit(self: *MySQLIter) void {
            if (self.stmt) |s| {
                _ = c.mysql_stmt_close(s);
                self.stmt = null;
            }
            for (self.col_names) |n| self.allocator.free(n);
            if (self.col_names.len > 0) self.allocator.free(self.col_names);
            if (self.col_bufs.len > 0) self.allocator.free(self.col_bufs);
            if (self.bind_slice.len > 0) self.allocator.free(self.bind_slice);
        }
    };

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

        // Cache field types so the row loop can dispatch typed decodes.
        // Text protocol always delivers strings, but we still want the
        // natural Cell variant for ints/floats to avoid parseInt at consumer
        // reads. For text protocol we parseInt/parseFloat here once.
        var col_types = try allocator.alloc(c_int, n_cols);
        defer allocator.free(col_types);
        for (0..n_cols) |i| col_types[i] = fields[i].type;

        var result_set = ResultSet.init(allocator, columns);
        errdefer result_set.deinit();

        while (true) {
            const row = c.mysql_fetch_row(res) orelse break;
            const lengths = c.mysql_fetch_lengths(res);

            var cells = try allocator.alloc(Cell, n_cols);
            errdefer {
                for (cells) |cell| switch (cell) {
                    .text => |t| allocator.free(t),
                    .blob => |b| allocator.free(b),
                    else => {},
                };
                allocator.free(cells);
            }
            for (0..n_cols) |i| {
                if (row[i] == null) {
                    cells[i] = .null;
                } else {
                    const len: usize = @intCast(lengths[i]);
                    cells[i] = try mysqlTextToCell(allocator, row[i][0..len], col_types[i]);
                }
            }
            try result_set.addRow(cells);
        }

        return result_set;
    }

    pub const RawBinlogEvent = struct { buffer: [*c]const u8, size: c_ulong };

    /// Opens a binlog dump at `file:pos`. `file` must remain alive until binlogClose is called.
    pub fn binlogOpen(self: *MySQLDB, file: [:0]const u8, pos: u64) !void {
        if (self.conn == null) return error.ConnectionClosed;
        if (self.binlog_opened) return error.BinlogAlreadyOpen;

        var rpl: c.MYSQL_RPL = std.mem.zeroes(c.MYSQL_RPL);
        rpl.file_name_length = file.len;
        rpl.file_name = file.ptr;
        rpl.start_position = pos;
        rpl.server_id = DEFAULT_BINLOG_SERVER_ID;
        if (c.mysql_binlog_open(self.conn, &rpl) != 0) {
            std.debug.print("MySQL binlog open failed: {s}\n", .{c.mysql_error(self.conn)});
            return error.BinlogOpenFailed;
        }
        self.rpl = rpl;
        self.binlog_opened = true;
    }

    pub fn binlogFetch(self: *MySQLDB) !?RawBinlogEvent {
        if (self.rpl == null) return error.BinlogFetchFailed;
        const rpl = &self.rpl.?;
        if (c.mysql_binlog_fetch(self.conn, rpl) != 0) {
            std.debug.print("MySQL binlog fetch failed: {s}\n", .{c.mysql_error(self.conn)});
            return error.BinlogFetchFailed;
        }
        if (rpl.buffer == null or rpl.size == 0) return null;
        return RawBinlogEvent{ .buffer = rpl.buffer, .size = rpl.size };
    }

    pub fn binlogClose(self: *MySQLDB) void {
        if (self.conn) |conn| {
            if (self.rpl) |*rpl| {
                c.mysql_binlog_close(conn, rpl);
                self.rpl = null;
            }
        }
        self.binlog_opened = false;
    }

    /// Extract errno + message from a connection-level error.
    /// Borrowed slices — caller must keep conn/stmt alive.
    fn extractMysqlDiag(conn: *c.MYSQL) diag.Diag {
        const errno_val: u32 = c.mysql_errno(conn);
        const code = diag.mysqlCode(@intCast(errno_val));
        const message = std.mem.span(c.mysql_error(conn));
        // For unique_violation (errno 1062), try to extract the key name
        // from the message format: "Duplicate entry 'x' for key 'users.email'"
        var table: ?[]const u8 = null;
        var column: ?[]const u8 = null;
        if (code == .unique_violation) {
            if (extractDupKey(message)) |key| {
                if (std.mem.indexOfScalar(u8, key, '.')) |dot| {
                    table = key[0..dot];
                    column = key[dot + 1 ..];
                } else {
                    // Constraint name only — store it as the constraint field.
                    // Caller can decide whether to surface it.
                }
            }
        }
        return .{
            .code = code,
            .message = message,
            .table = table,
            .column = column,
            .raw = @tagName(code),
        };
    }

    /// Same as extractMysqlDiag but for stmt-level errors (mysql_stmt_error).
    fn extractMysqlStmtDiag(stmt: *c.MYSQL_STMT) diag.Diag {
        const errno_val: u32 = c.mysql_stmt_errno(stmt);
        const code = diag.mysqlCode(@intCast(errno_val));
        const message = std.mem.span(c.mysql_stmt_error(stmt));
        return .{
            .code = code,
            .message = message,
            .raw = @tagName(code),
        };
    }

    /// Find "for key 'X'" inside a MySQL duplicate-entry message and
    /// return the X slice. Returns null if the format is unrecognized.
    fn extractDupKey(message: []const u8) ?[]const u8 {
        const needle = "for key '";
        const start = std.mem.indexOf(u8, message, needle) orelse return null;
        const key_start = start + needle.len;
        const end = std.mem.indexOfScalar(u8, message[key_start..], '\'') orelse return null;
        return message[key_start..key_start + end];
    }

    /// Per-column output buffer for the binary-result fetch loop.
    /// Holds the MYSQL_BIND descriptor and the actual storage for the
    /// fetched value (int / float / text / blob).
    const ColumnBuf = struct {
        bind: c.MYSQL_BIND = .{},
        int_buf: i64 = 0,
        float_buf: f64 = 0,
        text_buf: [4096]u8 = undefined,
        length: c_ulong = 0,
        is_null: bool = false,
        is_err: bool = false,
    };

    /// Map MySQL field type → MYSQL_BIND buffer_type for binary fetch.
    /// Numeric types ask libmysqlclient for native binary; everything else
    /// falls back to MYSQL_TYPE_STRING (text protocol).
    fn mysqlBindType(ft: c_int) c_int {
        return switch (ft) {
            c.MYSQL_TYPE_TINY,
            c.MYSQL_TYPE_SHORT,
            c.MYSQL_TYPE_INT24,
            c.MYSQL_TYPE_LONG,
            c.MYSQL_TYPE_LONGLONG,
            c.MYSQL_TYPE_BIT,
            => c.MYSQL_TYPE_LONGLONG,

            c.MYSQL_TYPE_FLOAT,
            c.MYSQL_TYPE_DOUBLE,
            c.MYSQL_TYPE_DECIMAL,
            c.MYSQL_TYPE_NEWDECIMAL,
            => c.MYSQL_TYPE_DOUBLE,

            c.MYSQL_TYPE_NULL => c.MYSQL_TYPE_NULL,

            else => c.MYSQL_TYPE_STRING,
        };
    }

    /// Read a single column's MYSQL_BIND buffer into the matching Cell variant.
    fn readMysqlCell(allocator: std.mem.Allocator, col: *const ColumnBuf) !Cell {
        if (col.is_null) return .null;
        return switch (col.bind.buffer_type) {
            c.MYSQL_TYPE_LONGLONG => .{ .int = col.int_buf },
            c.MYSQL_TYPE_DOUBLE => .{ .float = col.float_buf },
            c.MYSQL_TYPE_NULL => .null,
            else => blk: {
                const len: usize = @intCast(col.length);
                break :blk .{ .text = try allocator.dupe(u8, col.text_buf[0..len]) };
            },
        };
    }

    /// For text-protocol result rows: parse the text payload based on the
    /// column's declared SQL type and emit a typed Cell. Numeric columns
    /// get parsed once here (parseInt / parseFloat) so consumer reads via
    /// `Row.getInt()` / `Row.getFloat()` hit the cached typed value.
    fn mysqlTextToCell(allocator: std.mem.Allocator, text: []const u8, ft: c_int) !Cell {
        return switch (ft) {
            c.MYSQL_TYPE_TINY,
            c.MYSQL_TYPE_SHORT,
            c.MYSQL_TYPE_INT24,
            c.MYSQL_TYPE_LONG,
            c.MYSQL_TYPE_LONGLONG,
            c.MYSQL_TYPE_BIT,
            => .{ .int = try std.fmt.parseInt(i64, text, 10) },

            c.MYSQL_TYPE_FLOAT,
            c.MYSQL_TYPE_DOUBLE,
            c.MYSQL_TYPE_DECIMAL,
            c.MYSQL_TYPE_NEWDECIMAL,
            => .{ .float = try std.fmt.parseFloat(f64, text) },

            else => .{ .text = try allocator.dupe(u8, text) },
        };
    }
};
