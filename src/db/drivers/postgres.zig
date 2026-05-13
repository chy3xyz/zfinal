const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const ResultSet = @import("../result.zig").ResultSet;
const SqlParam = @import("../sql_param.zig").SqlParam;

const c = @cImport({
    @cInclude("libpq-fe.h");
});

pub const PostgresDB = struct {
    conn: ?*c.PGconn,
    allocator: std.mem.Allocator,
    last_affected: i64 = 0,

    pub fn connect(allocator: std.mem.Allocator, config: DBConfig) !PostgresDB {
        var conn_buf: [1024]u8 = undefined;
        const conn_str = try std.fmt.bufPrint(&conn_buf,
            "host={s} port={d} dbname={s} user={s} password={s}",
            .{
                config.host orelse "localhost",
                config.port orelse 5432,
                config.database,
                config.username orelse "",
                config.password orelse "",
            },
        );

        const conn = c.PQconnectdb(conn_str.ptr);
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
        if (self.conn == null) return false;
        return c.PQstatus(self.conn) == c.CONNECTION_OK;
    }

    pub fn exec(self: *PostgresDB, sql: [:0]const u8) !void {
        const res = c.PQexec(self.conn, sql.ptr);
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            const msg = c.PQerrorMessage(self.conn);
            std.debug.print("PostgreSQL exec failed: {s}\n", .{msg});
            return error.ExecFailed;
        }

        const s = std.mem.span(c.PQcmdTuples(res));
        self.last_affected = if (s.len > 0) std.fmt.parseInt(i64, s, 10) catch 0 else 0;
    }

    pub fn execParams(self: *PostgresDB, sql: [:0]const u8, params: []const SqlParam) !void {
        const bind = try buildParams(self.allocator, params);
        defer freeParams(self.allocator, bind);

        const res = c.PQexecParams(
            self.conn, sql.ptr, @intCast(params.len), null,
            bind.values.ptr, bind.lengths.ptr, bind.formats.ptr, 0,
        );
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            const msg = c.PQerrorMessage(self.conn);
            std.debug.print("PostgreSQL execParams failed: {s}\n", .{msg});
            return error.ExecFailed;
        }

        const s = std.mem.span(c.PQcmdTuples(res));
        self.last_affected = if (s.len > 0) std.fmt.parseInt(i64, s, 10) catch 0 else 0;
    }

    pub fn query(self: *PostgresDB, sql: [:0]const u8) !ResultSet {
        return self.queryParams(sql, &.{});
    }

    pub fn queryParams(self: *PostgresDB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        const bind = try buildParams(self.allocator, params);
        defer freeParams(self.allocator, bind);

        const res = c.PQexecParams(
            self.conn, sql.ptr, @intCast(params.len), null,
            bind.values.ptr, bind.lengths.ptr, bind.formats.ptr, 0,
        );
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_TUPLES_OK) {
            const msg = c.PQerrorMessage(self.conn);
            std.debug.print("PostgreSQL query failed: {s}\n", .{msg});
            return error.QueryFailed;
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
                .null => { values[i] = null; lengths[i] = 0; },
                .int => |v| {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                    strings[i] = s;
                    owned[i] = true;
                    values[i] = @ptrCast(s.ptr);
                    lengths[i] = 0;
                },
                .real => |v| {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                    strings[i] = s;
                    owned[i] = true;
                    values[i] = @ptrCast(s.ptr);
                    lengths[i] = 0;
                },
                .text => |v| {
                    values[i] = @constCast(@ptrCast(v.ptr));
                    lengths[i] = 0;
                },
                .blob => |v| {
                    values[i] = @constCast(@ptrCast(v.ptr));
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
};
