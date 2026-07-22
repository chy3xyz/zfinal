const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
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

        if (c.mysql_real_connect(conn, h.ptr, u.ptr, pw.ptr, db.ptr, config.port orelse 3306, null, 0) == null) {
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
                const d = extractMysqlStmtDiag(stmt);
                std.debug.print("MySQL fetch failed [errno {s}]: {s}\n", .{ d.raw, d.message });
                return diag.toError(d.code);
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
};
