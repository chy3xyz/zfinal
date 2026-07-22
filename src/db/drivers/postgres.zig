const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const ResultSet = @import("../result.zig").ResultSet;
const SqlParam = @import("../sql_param.zig").SqlParam;
const diag = @import("../diag.zig");

const c = @import("c_pg");

// PG_DIAG_* field codes — character constants from <libpq-fe.h>:
//   'C' SQLSTATE, 'M' primary message, 't' table, 'c' column, 'n' constraint.
const PG_DIAG_SQLSTATE: c_int = 'C';
const PG_DIAG_TABLE_NAME: c_int = 't';
const PG_DIAG_COLUMN_NAME: c_int = 'c';
const PG_DIAG_CONSTRAINT_NAME: c_int = 'n';
const PG_DIAG_MESSAGE_PRIMARY: c_int = 'M';

pub const PostgresDB = struct {
    conn: ?*c.PGconn,
    allocator: std.mem.Allocator,
    last_affected: i64 = 0,

    pub fn connect(allocator: std.mem.Allocator, config: DBConfig) !PostgresDB {
        var conn_buf: [1024]u8 = undefined;
        // Build the conninfo string. Optional keys are appended only if set.
        const base = try std.fmt.bufPrint(
            &conn_buf,
            "host={s} port={d} dbname={s} user={s} password={s} connect_timeout={d} client_encoding=UTF8",
            .{
                config.host orelse "localhost",
                config.port orelse 5432,
                config.database,
                config.username orelse "",
                config.password orelse "",
                config.timeout,
            },
        );
        conn_buf[base.len] = 0;

        // Append sslmode= if non-default. libpq's default is 'prefer' which
        // silently downgrades to non-SSL on failure — cloud DBs (RDS, Cloud SQL)
        // require an explicit 'require' or stricter.
        var ssl_buf: [64]u8 = undefined;
        const ssl_suffix: []const u8 = switch (config.ssl_mode) {
            .disable => blk: {
                const s = try std.fmt.bufPrint(&ssl_buf, " sslmode=disable", .{});
                break :blk s;
            },
            .prefer => "", // libpq default — no need to append
            .require => blk: {
                const s = try std.fmt.bufPrint(&ssl_buf, " sslmode=require", .{});
                break :blk s;
            },
            .verify_ca => blk: {
                const s = try std.fmt.bufPrint(&ssl_buf, " sslmode=verify-ca", .{});
                break :blk s;
            },
            .verify_full => blk: {
                const s = try std.fmt.bufPrint(&ssl_buf, " sslmode=verify-full", .{});
                break :blk s;
            },
        };

        // Compose final conninfo: base + suffix
        var final_buf: [1100]u8 = undefined;
        const final_len = base.len + ssl_suffix.len;
        if (final_len > final_buf.len) return error.ConnectionFailed;
        @memcpy(final_buf[0..base.len], base);
        @memcpy(final_buf[base.len..final_len], ssl_suffix);
        final_buf[final_len] = 0;
        const conn_str: [:0]const u8 = final_buf[0..final_len :0];

        const conn = c.PQconnectdb(conn_str);
        @memset(&conn_buf, 0);
        @memset(&ssl_buf, 0);
        @memset(&final_buf, 0);
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            const msg = c.PQerrorMessage(conn);
            std.debug.print("PostgreSQL connect failed: {s}\n", .{msg});
            c.PQfinish(conn);
            return error.ConnectionFailed;
        }

        return .{ .conn = conn, .allocator = allocator };
    }

    pub fn close(self: *PostgresDB) void {
        if (self.conn) |cxn| {
            c.PQfinish(cxn);
            self.conn = null;
        }
    }

    pub fn ping(self: *PostgresDB) bool {
        const cxn = self.conn orelse return false;
        // Defensive: verify pointer isn't a poisoned debug-allocator fill
        if (@intFromPtr(cxn) >= 0xaaaaaaaaaaaaaaaa) return false;
        return c.PQstatus(cxn) == c.CONNECTION_OK;
    }

    pub fn exec(self: *PostgresDB, sql: [:0]const u8) !void {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const res = c.PQexec(cxn, sql.ptr);
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            const d = extractPgDiag(res);
            std.debug.print("PostgreSQL exec failed [{s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        const s = std.mem.span(c.PQcmdTuples(res));
        self.last_affected = if (s.len > 0) std.fmt.parseInt(i64, s, 10) catch 0 else 0;
    }

    pub fn execParams(self: *PostgresDB, sql: [:0]const u8, params: []const SqlParam) !void {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const bind = try buildParams(self.allocator, params);
        defer freeParams(self.allocator, bind);

        const res = c.PQexecParams(
            cxn,
            sql.ptr,
            @intCast(params.len),
            null,
            bind.values.ptr,
            bind.lengths.ptr,
            bind.formats.ptr,
            0,
        );
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            const d = extractPgDiag(res);
            std.debug.print("PostgreSQL execParams failed [{s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        const s = std.mem.span(c.PQcmdTuples(res));
        self.last_affected = if (s.len > 0) std.fmt.parseInt(i64, s, 10) catch 0 else 0;
    }

    pub fn query(self: *PostgresDB, sql: [:0]const u8) !ResultSet {
        return self.queryParams(sql, &.{});
    }

    pub fn queryParams(self: *PostgresDB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const bind = try buildParams(self.allocator, params);
        defer freeParams(self.allocator, bind);

        const res = c.PQexecParams(
            cxn,
            sql.ptr,
            @intCast(params.len),
            null,
            bind.values.ptr,
            bind.lengths.ptr,
            bind.formats.ptr,
            0,
        );
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_TUPLES_OK) {
            const d = extractPgDiag(res);
            std.debug.print("PostgreSQL query failed [{s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        const n_cols: usize = @intCast(c.PQnfields(res));
        const n_rows: usize = @intCast(c.PQntuples(res));

        var columns = try self.allocator.alloc([]const u8, n_cols);
        errdefer self.allocator.free(columns);
        for (0..n_cols) |i| {
            columns[i] = try self.allocator.dupe(u8, std.mem.span(c.PQfname(res, @intCast(i))));
        }

        var result_set = ResultSet.init(self.allocator, columns);
        errdefer result_set.deinit();

        for (0..n_rows) |ri| {
            var cells = try self.allocator.alloc(?[]const u8, n_cols);
            errdefer {
                for (cells) |c_| if (c_) |v| self.allocator.free(v);
                self.allocator.free(cells);
            }
            for (0..n_cols) |ci| {
                if (c.PQgetisnull(res, @intCast(ri), @intCast(ci)) == 1) {
                    cells[ci] = null;
                } else {
                    const ptr = c.PQgetvalue(res, @intCast(ri), @intCast(ci));
                    const len: usize = @intCast(c.PQgetlength(res, @intCast(ri), @intCast(ci)));
                    cells[ci] = try self.allocator.dupe(u8, ptr[0..len]);
                }
            }
            try result_set.addRow(cells);
        }

        return result_set;
    }

    pub fn affectedRows(self: *PostgresDB) i64 {
        return self.last_affected;
    }

    pub fn lastInsertId(self: *PostgresDB) !i64 {
        var result = try self.query("SELECT lastval()");
        defer result.deinit();
        if (result.next()) {
            if (try result.getInt(0)) |id| return id;
        }
        return error.NoLastInsertId;
    }

    const Params = struct { values: []?[*:0]const u8, lengths: []c_int, formats: []c_int, strings: [][]const u8, owned: []bool };

    fn buildParams(allocator: std.mem.Allocator, params: []const SqlParam) !Params {
        var values = try allocator.alloc(?[*:0]const u8, params.len);
        errdefer allocator.free(values);
        var lengths = try allocator.alloc(c_int, params.len);
        errdefer allocator.free(lengths);
        var formats = try allocator.alloc(c_int, params.len);
        errdefer allocator.free(formats);
        var strings = try allocator.alloc([]const u8, params.len);
        errdefer allocator.free(strings);
        var owned = try allocator.alloc(bool, params.len);
        errdefer allocator.free(owned);
        @memset(owned, false);

        for (params, 0..) |p, i| {
            formats[i] = 0;
            switch (p) {
                .null => {
                    values[i] = null;
                    lengths[i] = 0;
                },
                .int => |v| {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                    defer allocator.free(s);
                    const s0 = try allocator.alloc(u8, s.len + 1);
                    @memcpy(s0[0..s.len], s);
                    s0[s.len] = 0;
                    strings[i] = s0;
                    owned[i] = true;
                    values[i] = @ptrCast(s0.ptr);
                    lengths[i] = 0;
                },
                .real => |v| {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                    defer allocator.free(s);
                    const s0 = try allocator.alloc(u8, s.len + 1);
                    @memcpy(s0[0..s.len], s);
                    s0[s.len] = 0;
                    strings[i] = s0;
                    owned[i] = true;
                    values[i] = @ptrCast(s0.ptr);
                    lengths[i] = 0;
                },
                .text => |v| {
                    const s = try allocator.alloc(u8, v.len + 1);
                    @memcpy(s[0..v.len], v);
                    s[v.len] = 0;
                    strings[i] = s;
                    owned[i] = true;
                    values[i] = @ptrCast(s.ptr);
                    lengths[i] = 0;
                },
                .blob => |v| {
                    values[i] = @ptrCast(@constCast(v.ptr));
                    lengths[i] = @intCast(v.len);
                    formats[i] = 1;
                },
            }
        }
        return .{ .values = values, .lengths = lengths, .formats = formats, .strings = strings, .owned = owned };
    }

    fn freeParams(allocator: std.mem.Allocator, p: Params) void {
        for (p.strings, p.owned) |s, own| if (own) allocator.free(s);
        allocator.free(p.strings);
        allocator.free(p.owned);
        allocator.free(p.values);
        allocator.free(p.lengths);
        allocator.free(p.formats);
    }

    /// Extract SQLSTATE + table/column/constraint from a failed PG result.
    /// All returned slices are borrowed from libpq-owned memory — do NOT
    /// free them. Caller must keep `res` alive until diag is consumed.
    fn extractPgDiag(res_opt: ?*c.PGresult) diag.Diag {
        const res = res_opt orelse {
            // No result — PQexec itself failed. Use PQerrorMessage on conn.
            return .{
                .code = .connection_lost,
                .message = "(no result)",
                .raw = "",
            };
        };
        const sqlstate_ptr = c.PQresultErrorField(res, PG_DIAG_SQLSTATE);
        const sqlstate = if (sqlstate_ptr) |p| std.mem.span(p) else "";
        const code = diag.pgCode(sqlstate);

        const msg_ptr = c.PQresultErrorField(res, PG_DIAG_MESSAGE_PRIMARY);
        const message = if (msg_ptr) |p| std.mem.span(p) else "";

        const table_ptr = c.PQresultErrorField(res, PG_DIAG_TABLE_NAME);
        const table: ?[]const u8 = if (table_ptr) |p| std.mem.span(p) else null;

        const col_ptr = c.PQresultErrorField(res, PG_DIAG_COLUMN_NAME);
        const column: ?[]const u8 = if (col_ptr) |p| std.mem.span(p) else null;

        const cn_ptr = c.PQresultErrorField(res, PG_DIAG_CONSTRAINT_NAME);
        const constraint: ?[]const u8 = if (cn_ptr) |p| std.mem.span(p) else null;

        return .{
            .code = code,
            .message = message,
            .table = table,
            .column = column,
            .constraint = constraint,
            .raw = sqlstate,
        };
    }
};
