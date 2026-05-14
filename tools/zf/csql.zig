const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const Column = @import("codegen.zig").Column;
const Table = @import("codegen.zig").Table;

/// Extract table schemas by importing SQL into a temp SQLite DB and introspecting.
/// Much more reliable than hand-parsing SQL text.
pub fn extractFromSql(allocator: std.mem.Allocator, sql: []const u8) !std.ArrayList(Table) {
    var db: ?*c.sqlite3 = null;
    var err_msg: [*c]u8 = undefined;

    // Open in-memory database
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
        const msg: [*c]const u8 = if (db != null) c.sqlite3_errmsg(db) else @ptrCast("unknown");
        std.debug.print("sqlite3_open failed: {s}\n", .{msg});
        return error.SqliteOpen;
    }
    defer _ = c.sqlite3_close(db);

    // Execute the SQL file
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    if (c.sqlite3_exec(db, sql_z.ptr, null, null, &err_msg) != c.SQLITE_OK) {
        std.debug.print("sqlite3_exec schema: {s}\n", .{err_msg});
        c.sqlite3_free(err_msg);
        return error.SqliteExec;
    }

    // Get table names from sqlite_master
    var tables = std.ArrayList(Table).empty;

    const master_sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name";
    var stmt: ?*c.sqlite3_stmt = undefined;
    if (c.sqlite3_prepare_v2(db, master_sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("sqlite3_prepare master: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.SqlitePrepare;
    }
    defer _ = c.sqlite3_finalize(stmt);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const table_name_raw = c.sqlite3_column_text(stmt, 0);
        const table_name = try allocator.dupe(u8, std.mem.span(table_name_raw));
        const pascal_name = try toPascalCase(allocator, table_name);

        var columns = std.ArrayList(Column).empty;

        // PRAGMA table_info for column details
        const info_sql = try std.fmt.allocPrint(allocator, "PRAGMA table_info(\"{s}\")", .{table_name});
        defer allocator.free(info_sql);
        const info_z = try allocator.dupeZ(u8, info_sql);
        defer allocator.free(info_z);

        var info_stmt: ?*c.sqlite3_stmt = undefined;
        if (c.sqlite3_prepare_v2(db, info_z.ptr, -1, &info_stmt, null) != c.SQLITE_OK) {
            std.debug.print("PRAGMA table_info failed for {s}: {s}\n", .{ table_name, c.sqlite3_errmsg(db) });
            continue;
        }
        defer _ = c.sqlite3_finalize(info_stmt);

        while (c.sqlite3_step(info_stmt) == c.SQLITE_ROW) {
            const col_name_raw = c.sqlite3_column_text(info_stmt, 1); // name
            const col_type_raw = c.sqlite3_column_text(info_stmt, 2); // type
            const not_null = c.sqlite3_column_int(info_stmt, 3); // notnull
            const default_raw = c.sqlite3_column_text(info_stmt, 4); // dflt_value
            const pk = c.sqlite3_column_int(info_stmt, 5); // pk

            const col_name = try allocator.dupe(u8, std.mem.span(col_name_raw));
            const col_type = try allocator.dupe(u8, std.mem.span(col_type_raw));
            const default_val: ?[]const u8 = if (default_raw != null) try allocator.dupe(u8, std.mem.span(default_raw)) else null;

            // AUTOINCREMENT detection: if pk > 0 AND type contains INTEGER
            const is_autoinc = pk > 0 and std.ascii.indexOfIgnoreCase(col_type, "INTEGER") != null;

            try columns.append(allocator, .{
                .name = col_name,
                .sql_type = col_type,
                .is_nullable = not_null == 0,
                .is_primary_key = pk > 0,
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

    std.debug.print("Extracted {d} tables from database introspection\n", .{tables.items.len});
    return tables;
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
