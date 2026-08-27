const std = @import("std");
const c = @import("c_sqlite3");

const Column = @import("codegen").Column;
const Table = @import("codegen").Table;

/// Extract table schemas by importing SQL into a temp SQLite DB and introspecting.
/// Filters out INSERT/UPDATE/DELETE — only executes DDL (CREATE TABLE/INDEX).
/// Handles large dump files (INSERTs are skipped, not loaded into memory).
pub fn extractFromSql(allocator: std.mem.Allocator, sql: []const u8) !std.ArrayList(Table) {
    var db: ?*c.sqlite3 = null;
    var err_msg: [*c]u8 = undefined;

    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
        const msg: [*c]const u8 = if (db != null) c.sqlite3_errmsg(db) else @ptrCast("unknown");
        std.debug.print("sqlite3_open failed: {s}\n", .{msg});
        return error.SqliteOpen;
    }
    defer _ = c.sqlite3_close(db);

    // Filter to DDL only (CREATE TABLE/INDEX) — skip INSERTs that may be huge
    const ddl = try filterDdl(allocator, sql);
    defer allocator.free(ddl);
    std.debug.print("   SQL: {d} bytes total → {d} bytes DDL (CREATE TABLE only)\n", .{ sql.len, ddl.len });

    const sql_z = try allocator.allocSentinel(u8, ddl.len, 0);
    @memcpy(sql_z, ddl);
    defer allocator.free(sql_z);
    if (c.sqlite3_exec(db, sql_z.ptr, null, null, &err_msg) != c.SQLITE_OK) {
        std.debug.print("sqlite3_exec schema: {s}\n", .{err_msg});
        c.sqlite3_free(err_msg);
        diagnoseDdlFailure(allocator, sql);
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
        const info_z = try allocator.allocSentinel(u8, info_sql.len, 0);
        @memcpy(info_z, info_sql);
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
            const is_autoinc = pk > 0 and std.ascii.startsWithIgnoreCase(col_type, "INTEGER");

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

    // Apply `-- @filter` / `-- @search` / `-- @sortable` / `-- @hidden`
    // column annotations from the raw CREATE TABLE statements.
    @import("codegen").applyColumnAnnotations(sql, &tables);

    std.debug.print("Extracted {d} tables from database introspection\n", .{tables.items.len});
    return tables;
}

/// Filter SQL to DDL only (CREATE TABLE, CREATE INDEX).
/// Skips INSERT, UPDATE, DELETE, DROP, ALTER, comments, etc.
/// Reduces multi-GB dump files to KB of schema for sqlite3 import.
fn filterDdl(allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;

    while (i < sql.len) {
        // Skip whitespace
        while (i < sql.len and (sql[i] == ' ' or sql[i] == '\n' or sql[i] == '\r' or sql[i] == '\t')) i += 1;
        if (i >= sql.len) break;

        // Skip single-line comments
        if (i + 1 < sql.len and sql[i] == '-' and sql[i + 1] == '-') {
            while (i < sql.len and sql[i] != '\n') i += 1;
            continue;
        }
        // Skip block comments
        if (i + 1 < sql.len and sql[i] == '/' and sql[i + 1] == '*') {
            i += 2;
            while (i + 1 < sql.len) {
                if (sql[i] == '*' and sql[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Check if this statement starts with CREATE
        const is_create = isCreateKeyword(sql, i);

        if (is_create) {
            const start = i;
            // Find the semicolon ending this statement
            while (i < sql.len and sql[i] != ';') i += 1;
            if (i < sql.len) i += 1; // skip semicolon
            try out.appendSlice(allocator, sql[start..i]);
            try out.append(allocator, '\n');
        } else {
            // Skip non-DDL statement: find next semicolon
            while (i < sql.len and sql[i] != ';') i += 1;
            if (i < sql.len) i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

// ─── C1: generator error diagnostics ────────────────────────────────────
//
// `zf crud:sql` validates schemas by running them through SQLite
// introspection. When the combined DDL exec fails, the bare sqlite error
// gives no location — AI consumers retry blind. These helpers re-run each
// CREATE in isolation to name the offending statement, its source line,
// a snippet, and the common causes.

fn isCreateKeyword(sql: []const u8, at: usize) bool {
    if (at + 6 > sql.len) return false;
    const word = "create";
    for (word, 0..) |ch, k| {
        if (std.ascii.toLower(sql[at + k]) != ch) return false;
    }
    return true;
}

/// 1-based source line of byte offset `off`.
pub fn lineOfOffset(sql: []const u8, off: usize) usize {
    var line: usize = 1;
    for (sql[0..@min(off, sql.len)]) |ch| {
        if (ch == '\n') line += 1;
    }
    return line;
}

/// Start offsets of every CREATE statement kept by `filterDdl`.
pub fn ddlStatementOffsets(allocator: std.mem.Allocator, sql: []const u8) !std.ArrayList(usize) {
    var offsets = std.ArrayList(usize).empty;
    errdefer offsets.deinit(allocator);
    var i: usize = 0;

    while (i < sql.len) {
        while (i < sql.len and (sql[i] == ' ' or sql[i] == '\n' or sql[i] == '\r' or sql[i] == '\t')) i += 1;
        if (i >= sql.len) break;

        if (i + 1 < sql.len and sql[i] == '-' and sql[i + 1] == '-') {
            while (i < sql.len and sql[i] != '\n') i += 1;
            continue;
        }
        if (i + 1 < sql.len and sql[i] == '/' and sql[i + 1] == '*') {
            i += 2;
            while (i + 1 < sql.len) {
                if (sql[i] == '*' and sql[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }

        const start = i;
        const is_create = isCreateKeyword(sql, i);
        while (i < sql.len and sql[i] != ';') i += 1;
        if (i < sql.len) i += 1;
        if (is_create) try offsets.append(allocator, start);
    }
    return offsets;
}

/// Re-run each CREATE statement on a fresh :memory: DB to identify the one
/// SQLite rejected; print its source line + snippet + likely causes.
fn diagnoseDdlFailure(allocator: std.mem.Allocator, sql: []const u8) void {
    var offsets = ddlStatementOffsets(allocator, sql) catch return;
    defer offsets.deinit(allocator);

    std.debug.print("\nerror: your SQL failed SQLite introspection — diagnosing {d} CREATE statement(s):\n", .{offsets.items.len});

    for (offsets.items, 0..) |start, idx| {
        var end = start;
        while (end < sql.len and sql[end] != ';') end += 1;
        const stmt_raw = std.mem.trim(u8, sql[start..end], " \t\r\n");
        if (stmt_raw.len == 0) continue;

        const stmt_z = allocator.allocSentinel(u8, stmt_raw.len, 0) catch continue;
        defer allocator.free(stmt_z);
        @memcpy(stmt_z, stmt_raw);

        var err_msg: [*c]u8 = undefined;
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_close(db);
        if (c.sqlite3_exec(db, stmt_z.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            const snippet = if (stmt_raw.len > 160) stmt_raw[0..160] else stmt_raw;
            std.debug.print(
                \\
                \\→ statement {d}/{d} FAILED (source line ~{d}):
                \\    {s}{s}
                \\  sqlite says: {s}
                \\
                \\hints:
                \\  • zf imports your schema into an in-memory SQLite to introspect it.
                \\    MySQL/PG-only column clauses are not valid there: UNSIGNED, ZEROFILL,
                \\    COMMENT '…', ON UPDATE CURRENT_TIMESTAMP, SERIAL (use INTEGER instead).
                \\  • Table suffixes like ENGINE=InnoDB / DEFAULT CHARSET=… are stripped
                \\    automatically; column-level MySQL clauses are NOT — remove them.
                \\  • Unbalanced quotes/parens earlier in this statement also land here.
                \\  • The text parser fallback still runs after this diagnosis.
                \\
            , .{ idx + 1, offsets.items.len, lineOfOffset(sql, start), snippet, if (stmt_raw.len > 160) " …" else "", err_msg });
            c.sqlite3_free(err_msg);
            return;
        }
    }
    std.debug.print("   all statements pass individually — failure may come from ORDER-dependent DDL (index before table?).\n", .{});
}

test "csql: lineOfOffset counts lines up to offset" {
    const sql = "a\nbb\nccc";
    try std.testing.expectEqual(@as(usize, 1), lineOfOffset(sql, 0));
    try std.testing.expectEqual(@as(usize, 2), lineOfOffset(sql, 3));
    try std.testing.expectEqual(@as(usize, 3), lineOfOffset(sql, 7));
    try std.testing.expectEqual(@as(usize, 3), lineOfOffset(sql, 100));
}

test "csql: ddlStatementOffsets finds only CREATE statements" {
    const a = std.testing.allocator;
    const sql =
        \\INSERT INTO t VALUES (1); CREATE TABLE users (id INT);
        \\-- comment CREATE FAKE
        \\CREATE INDEX idx_users ON users(id);
        \\DROP TABLE x;
    ;
    var offsets = try ddlStatementOffsets(a, sql);
    defer offsets.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), offsets.items.len);
    try std.testing.expect(std.ascii.startsWithIgnoreCase(sql[offsets.items[0]..], "CREATE TABLE"));
    try std.testing.expect(std.ascii.startsWithIgnoreCase(sql[offsets.items[1]..], "CREATE INDEX"));
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
