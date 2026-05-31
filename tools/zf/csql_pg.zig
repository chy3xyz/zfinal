const std = @import("std");
const c = @import("c_pg");

const Column = @import("codegen.zig").Column;
const Table = @import("codegen.zig").Table;

/// PostgreSQL DSN: postgres://user:pass@host:port/dbname  or  postgresql://...
pub const Dsn = struct {
    user: []const u8 = "",
    password: []const u8 = "",
    host: []const u8 = "localhost",
    port: u16 = 5432,
    dbname: []const u8 = "",

    pub fn parse(allocator: std.mem.Allocator, url: []const u8) !Dsn {
        var dsn = Dsn{};
        var rest = url;

        // Strip scheme
        if (std.mem.startsWith(u8, rest, "postgresql://")) {
            rest = rest["postgresql://".len..];
        } else if (std.mem.startsWith(u8, rest, "postgres://")) {
            rest = rest["postgres://".len..];
        } else {
            return error.InvalidDsn;
        }

        // user:pass@host:port/dbname
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
                dsn.port = std.fmt.parseInt(u16, host_port[colon_pos + 1 ..], 10) catch 5432;
            } else if (host_port.len > 0) {
                dsn.host = try allocator.dupe(u8, host_port);
            }
        } else {
            dsn.dbname = try allocator.dupe(u8, rest);
        }

        return dsn;
    }

    pub fn deinit(self: *Dsn, allocator: std.mem.Allocator) void {
        if (self.user.len > 0) allocator.free(self.user);
        if (self.password.len > 0) allocator.free(self.password);
        if (self.host.len > 0 and !std.mem.eql(u8, self.host, "localhost")) allocator.free(self.host);
        if (self.dbname.len > 0) allocator.free(self.dbname);
    }
};

/// Connect to PostgreSQL and introspect schema via information_schema.
pub fn extractFromDb(allocator: std.mem.Allocator, dsn: Dsn) !std.ArrayList(Table) {
    // Build PQconninfo
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{dsn.port});
    defer allocator.free(port_str);

    const keywords = [_][*c]const u8{
        "host",         "port",      "dbname",
        "user",         "password",
        "connect_timeout",
        null,
    };
    const values = [_][*c]const u8{
        @ptrCast(dsn.host.ptr),     @ptrCast(port_str.ptr),   @ptrCast(dsn.dbname.ptr),
        if (dsn.user.len > 0) @ptrCast(dsn.user.ptr) else @ptrCast("postgres"),
        if (dsn.password.len > 0) @ptrCast(dsn.password.ptr) else @ptrCast(""),
        "5",
        null,
    };

    const conn = c.PQconnectdbParams(@ptrCast(&keywords), @ptrCast(&values), 0);
    defer c.PQfinish(conn);

    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        std.debug.print("PG connection failed: {s}\n", .{c.PQerrorMessage(conn)});
        return error.PgConnect;
    }
    std.debug.print("Connected to PostgreSQL: {s}:{d}/{s}\n", .{ dsn.host, dsn.port, dsn.dbname });

    // Query tables from information_schema
    const table_sql =
        \\SELECT table_name FROM information_schema.tables
        \\WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        \\ORDER BY table_name
    ;
    const table_res = c.PQexec(conn, table_sql);
    defer c.PQclear(table_res);

    if (c.PQresultStatus(table_res) != c.PGRES_TUPLES_OK) {
        std.debug.print("PG query failed: {s}\n", .{c.PQerrorMessage(conn)});
        return error.PgQuery;
    }

    var tables = std.ArrayList(Table).empty;
    const n_tables = c.PQntuples(table_res);

    for (0..@intCast(n_tables)) |i| {
        const table_name_raw = c.PQgetvalue(table_res, @intCast(i), 0);
        const table_name = try allocator.dupe(u8, std.mem.span(table_name_raw));
        const pascal_name = try toPascalCase(allocator, table_name);

        // PRAGMA-style: query columns via information_schema
        const col_sql = try std.fmt.allocPrint(allocator,
            \\SELECT column_name, data_type, is_nullable, column_default,
            \\       CASE WHEN column_name = 'id' AND data_type = 'integer' THEN 'YES' ELSE 'NO' END as is_pk
            \\FROM information_schema.columns
            \\WHERE table_schema = 'public' AND table_name = '{s}'
            \\ORDER BY ordinal_position
        , .{table_name});
        defer allocator.free(col_sql);

        const col_res = c.PQexec(conn, @ptrCast(col_sql.ptr));
        defer c.PQclear(col_res);
        // Hmm, PQexec expects null-terminated, let's use the col_sql as-is since allocPrint returns null-terminated in Zig

        var columns = std.ArrayList(Column).empty;
        const n_cols = c.PQntuples(col_res);

        for (0..@intCast(n_cols)) |j| {
            const col_name_raw = c.PQgetvalue(col_res, @intCast(j), 0);
            const col_type_raw = c.PQgetvalue(col_res, @intCast(j), 1);
            const nullable_raw = c.PQgetvalue(col_res, @intCast(j), 2);
            const default_raw = c.PQgetvalue(col_res, @intCast(j), 3);

            const col_name = try allocator.dupe(u8, std.mem.span(col_name_raw));
            const pg_type = std.mem.span(col_type_raw);
            const is_nullable = std.mem.eql(u8, std.mem.span(nullable_raw), "YES");
            const is_pk = std.mem.eql(u8, col_name, "id"); // Heuristic — real PK check would need pg_constraint
            const is_autoinc = is_pk and (std.mem.eql(u8, pg_type, "integer") or std.mem.eql(u8, pg_type, "bigint") or std.mem.eql(u8, pg_type, "smallint"));

            const default_val: ?[]const u8 = if (default_raw != null and default_raw[0] != 0)
                try allocator.dupe(u8, std.mem.span(default_raw))
            else
                null;

            // Map PG type to Zig type label
            const zig_type = mapPgType(allocator, pg_type) catch "[]const u8";
            defer allocator.free(zig_type);

            try columns.append(allocator, .{
                .name = col_name,
                .sql_type = zig_type,
                .is_nullable = is_nullable,
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

    std.debug.print("Extracted {d} tables from PostgreSQL\n", .{tables.items.len});
    return tables;
}

/// Map PostgreSQL type to Zig type label used by codegen.zigType().
fn mapPgType(allocator: std.mem.Allocator, pg_type: []const u8) ![]const u8 {
    const upper = try std.ascii.allocUpperString(allocator, pg_type);
    defer allocator.free(upper);

    if (std.mem.eql(u8, upper, "INTEGER") or std.mem.eql(u8, upper, "INT") or std.mem.eql(u8, upper, "INT4")) return allocator.dupe(u8, "INTEGER");
    if (std.mem.eql(u8, upper, "BIGINT") or std.mem.eql(u8, upper, "INT8") or std.mem.eql(u8, upper, "BIGSERIAL") or std.mem.eql(u8, upper, "SERIAL8")) return allocator.dupe(u8, "BIGINT");
    if (std.mem.eql(u8, upper, "SMALLINT") or std.mem.eql(u8, upper, "INT2")) return allocator.dupe(u8, "SMALLINT");
    if (std.mem.eql(u8, upper, "SERIAL") or std.mem.eql(u8, upper, "SERIAL4")) return allocator.dupe(u8, "SERIAL");
    if (std.mem.eql(u8, upper, "BOOLEAN") or std.mem.eql(u8, upper, "BOOL")) return allocator.dupe(u8, "BOOLEAN");
    if (std.mem.eql(u8, upper, "REAL") or std.mem.eql(u8, upper, "FLOAT4")) return allocator.dupe(u8, "REAL");
    if (std.mem.eql(u8, upper, "DOUBLE PRECISION") or std.mem.eql(u8, upper, "FLOAT8")) return allocator.dupe(u8, "DOUBLE");
    if (std.mem.eql(u8, upper, "NUMERIC") or std.mem.eql(u8, upper, "DECIMAL")) return allocator.dupe(u8, "DECIMAL(10,2)");
    if (std.mem.eql(u8, upper, "TIMESTAMP") or std.mem.eql(u8, upper, "TIMESTAMP WITHOUT TIME ZONE")) return allocator.dupe(u8, "TIMESTAMP");
    if (std.mem.eql(u8, upper, "TIMESTAMPTZ") or std.mem.eql(u8, upper, "TIMESTAMP WITH TIME ZONE")) return allocator.dupe(u8, "TIMESTAMP");
    if (std.mem.eql(u8, upper, "DATE")) return allocator.dupe(u8, "DATE");
    if (std.mem.eql(u8, upper, "TEXT") or std.mem.eql(u8, upper, "VARCHAR") or std.mem.eql(u8, upper, "CHARACTER VARYING")) return allocator.dupe(u8, "TEXT");
    if (std.mem.eql(u8, upper, "UUID")) return allocator.dupe(u8, "UUID");
    if (std.mem.eql(u8, upper, "JSON") or std.mem.eql(u8, upper, "JSONB")) return allocator.dupe(u8, "JSON");
    if (std.mem.eql(u8, upper, "BYTEA")) return allocator.dupe(u8, "BYTEA");

    return allocator.dupe(u8, "TEXT"); // fallback
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
