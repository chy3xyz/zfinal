const std = @import("std");
const c = @import("c_mysql");

const Column = @import("codegen").Column;
const Table = @import("codegen").Table;

/// MySQL DSN: mysql://user:pass@host:port/dbname
pub const Dsn = struct {
    user: []const u8 = "root",
    password: []const u8 = "",
    host: []const u8 = "localhost",
    port: u16 = 3306,
    dbname: []const u8 = "",

    pub fn parse(allocator: std.mem.Allocator, url: []const u8) !Dsn {
        var dsn = Dsn{};
        var rest = url;

        if (std.mem.startsWith(u8, rest, "mysql://")) {
            rest = rest["mysql://".len..];
        } else {
            return error.InvalidDsn;
        }

        if (std.mem.indexOfScalar(u8, rest, '@')) |at_pos| {
            const user_pass = rest[0..at_pos];
            rest = rest[at_pos + 1 ..];

            if (std.mem.indexOfScalar(u8, user_pass, ':')) |colon_pos| {
                dsn.user = try allocator.dupe(u8, user_pass[0..colon_pos]);
                dsn.password = try allocator.dupe(u8, user_pass[colon_pos + 1 ..]);
            } else {
                dsn.user = try allocator.dupe(u8, user_pass);
            }
        }

        if (std.mem.indexOfScalar(u8, rest, '/')) |slash_pos| {
            const host_port = rest[0..slash_pos];
            dsn.dbname = try allocator.dupe(u8, rest[slash_pos + 1 ..]);

            if (std.mem.indexOfScalar(u8, host_port, ':')) |colon_pos| {
                dsn.host = try allocator.dupe(u8, host_port[0..colon_pos]);
                dsn.port = std.fmt.parseInt(u16, host_port[colon_pos + 1 ..], 10) catch 3306;
            } else if (host_port.len > 0) {
                dsn.host = try allocator.dupe(u8, host_port);
            }
        } else {
            dsn.dbname = try allocator.dupe(u8, rest);
        }

        return dsn;
    }

    pub fn deinit(self: *Dsn, allocator: std.mem.Allocator) void {
        if (self.user.len > 0 and !std.mem.eql(u8, self.user, "root")) allocator.free(self.user);
        if (self.password.len > 0) allocator.free(self.password);
        if (self.host.len > 0 and !std.mem.eql(u8, self.host, "localhost")) allocator.free(self.host);
        if (self.dbname.len > 0) allocator.free(self.dbname);
    }
};

/// Connect to MySQL and introspect schema via INFORMATION_SCHEMA.
pub fn extractFromDb(allocator: std.mem.Allocator, dsn: Dsn) !std.ArrayList(Table) {
    var conn: c.MYSQL = undefined;
    if (c.mysql_init(&conn) == null) {
        return error.MysqlInit;
    }
    defer c.mysql_close(&conn);

    const user_raw = if (dsn.user.len > 0) dsn.user else "root";
    const user_z = try allocator.allocSentinel(u8, user_raw.len, 0);
    @memcpy(user_z, user_raw);
    defer allocator.free(user_z);
    const pass_z = try allocator.allocSentinel(u8, dsn.password.len, 0);
    @memcpy(pass_z, dsn.password);
    defer allocator.free(pass_z);
    const host_z = try allocator.allocSentinel(u8, dsn.host.len, 0);
    @memcpy(host_z, dsn.host);
    defer allocator.free(host_z);
    const db_z = try allocator.allocSentinel(u8, dsn.dbname.len, 0);
    @memcpy(db_z, dsn.dbname);
    defer allocator.free(db_z);

    _ = c.mysql_real_connect(&conn, host_z.ptr, user_z.ptr, pass_z.ptr, db_z.ptr, dsn.port, null, 0);
    if (c.mysql_error(&conn)[0] != 0) {
        std.debug.print("MySQL connection failed: {s}\n", .{c.mysql_error(&conn)});
        return error.MysqlConnect;
    }
    std.debug.print("Connected to MySQL: {s}:{d}/{s}\n", .{ dsn.host, dsn.port, dsn.dbname });

    // Get tables
    if (c.mysql_query(&conn, "SHOW TABLES") != 0) {
        std.debug.print("MySQL query failed: {s}\n", .{c.mysql_error(&conn)});
        return error.MysqlQuery;
    }

    const table_res = c.mysql_store_result(&conn) orelse return error.MysqlResult;
    defer c.mysql_free_result(table_res);

    var tables = std.ArrayList(Table).empty;
    const n_tables = c.mysql_num_rows(table_res);

    for (0..@intCast(n_tables)) |_| {
        const row = c.mysql_fetch_row(table_res);
        const table_name_raw = row.?[0];
        const table_name = try allocator.dupe(u8, std.mem.span(table_name_raw));
        const pascal_name = try toPascalCase(allocator, table_name);

        // DESCRIBE table
        const desc_sql = try std.fmt.allocPrint(allocator, "DESCRIBE `{s}`", .{table_name});
        defer allocator.free(desc_sql);
        const desc_z = try allocator.allocSentinel(u8, desc_sql.len, 0);
        @memcpy(desc_z, desc_sql);
        defer allocator.free(desc_z);

        if (c.mysql_query(&conn, desc_z.ptr) != 0) continue;

        const col_res = c.mysql_store_result(&conn) orelse continue;
        defer c.mysql_free_result(col_res);

        var columns = std.ArrayList(Column).empty;
        const n_cols = c.mysql_num_rows(col_res);

        for (0..@intCast(n_cols)) |_| {
            const col_row = c.mysql_fetch_row(col_res);
            if (col_row == null) continue;
            const fields = col_row.?;

            const col_name = try allocator.dupe(u8, std.mem.span(fields[0]));
            const col_type_raw = std.mem.span(fields[1]);
            const null_ok = std.mem.eql(u8, std.mem.span(fields[2]), "YES");
            const key = std.mem.span(fields[3]);
            const default_raw = fields[4];
            const extra = std.mem.span(fields[5]);

            const is_pk = std.mem.eql(u8, key, "PRI");
            const is_autoinc = std.mem.indexOf(u8, extra, "auto_increment") != null;

            // Map MySQL type to Zig type label
            const zig_type = mapMyType(allocator, col_type_raw) catch "[]const u8";
            defer allocator.free(zig_type);

            const default_val: ?[]const u8 = if (default_raw != null)
                try allocator.dupe(u8, std.mem.span(default_raw))
            else
                null;

            try columns.append(allocator, .{
                .name = col_name,
                .sql_type = zig_type,
                .is_nullable = null_ok,
                .is_primary_key = is_pk,
                .is_auto_increment = is_autoinc,
                .default_value = default_val,
                .max_length = null,
            });
        }

        try tables.append(allocator, .{
            .name = table_name,
            .pascal_name = pascal_name,
            .columns = columns,
            .allocator = allocator,
        });
    }

    std.debug.print("Extracted {d} tables from MySQL\n", .{tables.items.len});
    return tables;
}

fn mapMyType(allocator: std.mem.Allocator, mysql_type: []const u8) ![]const u8 {
    const lower = try std.ascii.allocLowerString(allocator, mysql_type);
    defer allocator.free(lower);

    // Strip length/parenthesis: int(11) -> int, varchar(255) -> varchar
    const base = if (std.mem.indexOfScalar(u8, lower, '(')) |p| lower[0..p] else lower;

    if (std.mem.eql(u8, base, "int") or std.mem.eql(u8, base, "mediumint")) return allocator.dupe(u8, "INTEGER");
    if (std.mem.eql(u8, base, "bigint")) return allocator.dupe(u8, "BIGINT");
    if (std.mem.eql(u8, base, "smallint") or std.mem.eql(u8, base, "tinyint")) return allocator.dupe(u8, "SMALLINT");
    if (std.mem.eql(u8, base, "tinyint(1)") or (std.mem.eql(u8, base, "tinyint") and std.mem.indexOf(u8, lower, "(1)") != null)) return allocator.dupe(u8, "TINYINT(1)");
    if (std.mem.eql(u8, base, "float")) return allocator.dupe(u8, "REAL");
    if (std.mem.eql(u8, base, "double")) return allocator.dupe(u8, "DOUBLE");
    if (std.mem.eql(u8, base, "decimal") or std.mem.eql(u8, base, "numeric")) return allocator.dupe(u8, "DECIMAL(10,2)");
    if (std.mem.eql(u8, base, "varchar") or std.mem.eql(u8, base, "char")) return allocator.dupe(u8, "VARCHAR");
    if (std.mem.eql(u8, base, "text") or std.mem.eql(u8, base, "mediumtext") or std.mem.eql(u8, base, "longtext")) return allocator.dupe(u8, "TEXT");
    if (std.mem.eql(u8, base, "datetime") or std.mem.eql(u8, base, "timestamp")) return allocator.dupe(u8, "DATETIME");
    if (std.mem.eql(u8, base, "date")) return allocator.dupe(u8, "DATE");
    if (std.mem.eql(u8, base, "blob") or std.mem.eql(u8, base, "longblob") or std.mem.eql(u8, base, "mediumblob")) return allocator.dupe(u8, "BLOB");
    if (std.mem.eql(u8, base, "json")) return allocator.dupe(u8, "JSON");
    if (std.mem.eql(u8, base, "enum")) return allocator.dupe(u8, "VARCHAR");

    return allocator.dupe(u8, "TEXT");
}

fn toPascalCase(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    var cap = true;
    for (name) |ch| {
        if (ch == '_') {
            cap = true;
            continue;
        }
        try result.append(allocator, if (cap) std.ascii.toUpper(ch) else ch);
        cap = false;
    }
    if (result.items.len == 0) return allocator.dupe(u8, "untitled");
    return result.toOwnedSlice(allocator);
}
