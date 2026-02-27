const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const ResultSet = @import("../result.zig").ResultSet;

const c = @cImport({
    @cInclude("mysql/mysql.h");
});

/// MySQL database driver using libmysqlclient
pub const MySQLDB = struct {
    conn: ?*c.MYSQL,
    allocator: std.mem.Allocator,
    last_affected: u64 = 0,

    /// Connect to MySQL database
    pub fn connect(allocator: std.mem.Allocator, config: DBConfig) !MySQLDB {
        const conn = c.mysql_init(null);
        if (conn == null) {
            return error.InitFailed;
        }

        // Convert strings to null-terminated
        var host_buf: [256]u8 = undefined;
        var user_buf: [256]u8 = undefined;
        var pass_buf: [256]u8 = undefined;
        var db_buf: [256]u8 = undefined;

        const host_z = try std.fmt.bufPrintZ(&host_buf, "{s}", .{config.host orelse "localhost"});
        const user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{config.username orelse "root"});
        const pass_z = try std.fmt.bufPrintZ(&pass_buf, "{s}", .{config.password orelse ""});
        const db_z = try std.fmt.bufPrintZ(&db_buf, "{s}", .{config.database});

        const result = c.mysql_real_connect(conn, host_z.ptr, user_z.ptr, pass_z.ptr, db_z.ptr, config.port orelse 3306, null, 0);

        if (result == null) {
            const err_msg = c.mysql_error(conn);
            std.debug.print("MySQL connection failed: {s}\n", .{err_msg});
            c.mysql_close(conn);
            return error.ConnectionFailed;
        }

        return MySQLDB{
            .conn = conn,
            .allocator = allocator,
        };
    }

    /// Close connection
    pub fn close(self: *MySQLDB) void {
        if (self.conn) |conn| {
            c.mysql_close(conn);
            self.conn = null;
        }
    }

    /// Execute SQL statement
    pub fn exec(self: *MySQLDB, sql: [:0]const u8) !void {
        const rc = c.mysql_query(self.conn, sql.ptr);
        if (rc != 0) {
            const err_msg = c.mysql_error(self.conn);
            std.debug.print("MySQL exec failed: {s}\n", .{err_msg});
            return error.ExecFailed;
        }

        self.last_affected = c.mysql_affected_rows(self.conn);
    }

    /// Execute query and return result set
    pub fn query(self: *MySQLDB, sql: [:0]const u8) !ResultSet {
        const rc = c.mysql_query(self.conn, sql.ptr);
        if (rc != 0) {
            const err_msg = c.mysql_error(self.conn);
            std.debug.print("MySQL query failed: {s}\n", .{err_msg});
            return error.QueryFailed;
        }

        const result = c.mysql_store_result(self.conn);
        if (result == null) {
            return error.StoreResultFailed;
        }
        defer c.mysql_free_result(result);

        // Get column names
        const n_fields = c.mysql_num_fields(result);
        var columns = try self.allocator.alloc([]const u8, @intCast(n_fields));

        const fields = c.mysql_fetch_fields(result);
        for (0..@intCast(n_fields)) |i| {
            const field = fields[i];
            const field_name_len = field.name_length;
            columns[i] = try self.allocator.dupe(u8, field.name[0..field_name_len]);
        }

        const result_set = ResultSet.init(self.allocator, columns);

        // Note: In a real implementation, we'd iterate through rows here
        // TODO: Implement row iteration

        return result_set;
    }

    /// Get last insert ID
    pub fn lastInsertId(self: *MySQLDB) !i64 {
        return @intCast(c.mysql_insert_id(self.conn));
    }

    /// Get number of affected rows
    pub fn affectedRows(self: *MySQLDB) !i64 {
        return @intCast(self.last_affected);
    }
};
