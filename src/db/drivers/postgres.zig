const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const ResultSet = @import("../result.zig").ResultSet;

const c = @cImport({
    @cInclude("libpq-fe.h");
});

/// PostgreSQL database driver using libpq
pub const PostgresDB = struct {
    conn: ?*c.PGconn,
    allocator: std.mem.Allocator,

    /// Connect to PostgreSQL database
    pub fn connect(allocator: std.mem.Allocator, config: DBConfig) !PostgresDB {
        // Build connection string
        var conn_str_buf: [512]u8 = undefined;
        const conn_str = try std.fmt.bufPrintZ(&conn_str_buf, "host={s} port={d} dbname={s} user={s} password={s}", .{
            config.host orelse "localhost",
            config.port orelse 5432,
            config.database,
            config.username orelse "",
            config.password orelse "",
        });

        const conn = c.PQconnectdb(conn_str.ptr);
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            const err_msg = c.PQerrorMessage(conn);
            std.debug.print("PostgreSQL connection failed: {s}\n", .{err_msg});
            _ = c.PQfinish(conn);
            return error.ConnectionFailed;
        }

        return PostgresDB{
            .conn = conn,
            .allocator = allocator,
        };
    }

    /// Close connection
    pub fn close(self: *PostgresDB) void {
        if (self.conn) |conn| {
            c.PQfinish(conn);
            self.conn = null;
        }
    }

    /// Execute SQL statement
    pub fn exec(self: *PostgresDB, sql: [:0]const u8) !void {
        const result = c.PQexec(self.conn, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("PostgreSQL exec failed: {s}\n", .{err_msg});
            return error.ExecFailed;
        }
    }

    /// Execute query and return result set
    pub fn query(self: *PostgresDB, sql: [:0]const u8) !ResultSet {
        const result = c.PQexec(self.conn, sql.ptr);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("PostgreSQL query failed: {s}\n", .{err_msg});
            c.PQclear(result);
            return error.QueryFailed;
        }

        // Get column names
        const n_fields = c.PQnfields(result);
        var columns = try self.allocator.alloc([]const u8, @intCast(n_fields));

        for (0..@intCast(n_fields)) |i| {
            const col_name = c.PQfname(result, @intCast(i));
            const col_name_len = std.mem.len(col_name);
            columns[i] = try self.allocator.dupe(u8, col_name[0..col_name_len]);
        }

        const result_set = ResultSet.init(self.allocator, columns);

        // Note: In a real implementation, we'd store the PGresult and iterate through rows
        // For now, we'll just return the structure
        // TODO: Implement row iteration

        c.PQclear(result);
        return result_set;
    }

    /// Get number of affected rows
    pub fn affectedRows(self: *PostgresDB) !i64 {
        // This would need to be tracked from the last exec/query
        _ = self;
        return 0;
    }
};
