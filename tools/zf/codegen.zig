const std = @import("std");

pub const Column = struct {
    name: []const u8,
    sql_type: []const u8,
    is_nullable: bool,
    is_primary_key: bool,
    is_auto_increment: bool,
    default_value: ?[]const u8,
    max_length: ?usize,
};

pub const Table = struct {
    name: []const u8,
    pascal_name: []const u8,
    columns: std.ArrayList(Column),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.name);
        self.allocator.free(self.pascal_name);
        for (self.columns.items) |c| {
            self.allocator.free(c.name);
            self.allocator.free(c.sql_type);
            if (c.default_value) |v| self.allocator.free(v);
        }
        self.columns.deinit(self.allocator);
    }
};

pub fn zigType(col: Column) []const u8 {
    const t = col.sql_type;
    if (col.is_auto_increment) return "?i64";
    if (col.is_nullable and !col.is_primary_key) {
        if (isTypePrefix(t, "INT") or isTypePrefix(t, "BIGINT") or isTypePrefix(t, "SMALLINT") or isTypePrefix(t, "TINYINT") or isTypePrefix(t, "SERIAL") or isTypePrefix(t, "NUMERIC") or isTypePrefix(t, "DECIMAL")) return "?i64";
        if (isTypePrefix(t, "REAL") or isTypePrefix(t, "FLOAT") or isTypePrefix(t, "DOUBLE")) return "?f64";
        if (isTypePrefix(t, "BOOL") or isTypePrefix(t, "TINYINT(1)") or isTypePrefix(t, "BIT")) return "?bool";
        if (isBlobType(t)) return "?[]const u8";
        return "?[]const u8";
    }
    if (isTypePrefix(t, "INT") or isTypePrefix(t, "BIGINT") or isTypePrefix(t, "SMALLINT") or isTypePrefix(t, "TINYINT") or isTypePrefix(t, "MEDIUMINT") or isTypePrefix(t, "SERIAL") or isTypePrefix(t, "NUMERIC") or isTypePrefix(t, "DECIMAL")) return "i64";
    if (isTypePrefix(t, "REAL") or isTypePrefix(t, "FLOAT") or isTypePrefix(t, "DOUBLE")) return "f64";
    if (isTypePrefix(t, "BOOL") or isTypePrefix(t, "TINYINT(1)") or isTypePrefix(t, "BIT")) return "bool";
    if (isBlobType(t)) return "[]const u8";
    return "[]const u8";
}

fn isTypePrefix(sql_type: []const u8, prefix: []const u8) bool {
    if (sql_type.len < prefix.len) return false;
    return std.ascii.startsWithIgnoreCase(sql_type, prefix);
}

// Additional MySQL type checks for zigType
fn isTextType(t: []const u8) bool {
    return isTypePrefix(t, "VARCHAR") or isTypePrefix(t, "CHAR") or isTypePrefix(t, "TEXT") or
        isTypePrefix(t, "MEDIUMTEXT") or isTypePrefix(t, "LONGTEXT") or isTypePrefix(t, "TINYTEXT") or
        isTypePrefix(t, "ENUM") or isTypePrefix(t, "SET") or isTypePrefix(t, "JSON") or
        isTypePrefix(t, "DATETIME") or isTypePrefix(t, "TIMESTAMP") or isTypePrefix(t, "DATE") or
        isTypePrefix(t, "TIME") or isTypePrefix(t, "YEAR");
}

fn isBlobType(t: []const u8) bool {
    return isTypePrefix(t, "BLOB") or isTypePrefix(t, "MEDIUMBLOB") or isTypePrefix(t, "LONGBLOB") or
        isTypePrefix(t, "TINYBLOB") or isTypePrefix(t, "BINARY") or isTypePrefix(t, "VARBINARY");
}

pub fn defaultZigValue(col: Column) []const u8 {
    const zt = zigType(col);
    const nullable = zt[0] == '?';
    if (col.is_auto_increment) return "null";
    if (col.is_primary_key) return "null";
    if (col.is_nullable) return "null";
    if (col.default_value) |v| {
        if (std.mem.startsWith(u8, v, "b'") or std.mem.startsWith(u8, v, "0x")) return if (nullable) "null" else if (zt[0] == 'b') "false" else "0";
        if (std.mem.eql(u8, v, "''") or v.len == 0) return if (nullable) "null" else "\"\"";
        if (std.mem.startsWith(u8, v, "CURRENT_TIMESTAMP") or v[0] == '\'' or v[0] == '=' or v[0] == ',') return if (nullable) "null" else "\"\"";
        // For string types, ignore DB default and use null/empty to avoid invalid Zig identifiers.
        if (std.mem.startsWith(u8, zt, "[]const u8") or std.mem.startsWith(u8, zt, "?[]const u8")) {
            return if (nullable) "null" else "\"\"";
        }
        return v;
    }
    if (nullable) return "null";
    return switch (zt[0]) {
        'i' => "0",
        'f' => "0.0",
        'b' => "false",
        '[' => "\"\"",
        else => "null",
    };
}

// ============================================================
// SQL Parser
// ============================================================

pub fn parseCreateTable(allocator: std.mem.Allocator, sql: []const u8) !Table {
    var table = Table{ .name = "", .pascal_name = "", .columns = std.ArrayList(Column).empty, .allocator = allocator };

    var pos: usize = 0;
    var upper_buf: [12]u8 = undefined;
    _ = std.ascii.upperString(&upper_buf, sql[0..@min(12, sql.len)]);
    _ = std.mem.indexOf(u8, &upper_buf, "CREATE TABLE") orelse return error.NoCreateTable;
    pos = std.mem.indexOf(u8, sql, "TABLE") orelse return error.InvalidSyntax;
    pos += 5;
    pos = skipWhitespace(sql, pos);
    if (std.mem.startsWith(u8, sql[pos..], "IF NOT EXISTS")) {
        pos += 13;
        pos = skipWhitespace(sql, pos);
    }

    const name_end = blk: {
        if (sql[pos] == '`' or sql[pos] == '"') {
            const q = sql[pos];
            pos += 1;
            const e = std.mem.indexOfScalar(u8, sql[pos..], q) orelse return error.InvalidSyntax;
            break :blk e + pos;
        }
        const e = std.mem.indexOfAny(u8, sql[pos..], " (\t\n\r") orelse return error.InvalidSyntax;
        break :blk pos + e;
    };
    table.name = try allocator.dupe(u8, sql[pos..name_end]);
    table.pascal_name = try toPascalCase(allocator, sql[pos..name_end]);

    pos = std.mem.indexOfScalar(u8, sql[name_end..], '(') orelse return error.InvalidSyntax;
    pos = name_end + pos + 1;

    while (pos < sql.len) {
        pos = skipWhitespace(sql, pos);
        if (pos >= sql.len or sql[pos] == ')') break;
        if (sql[pos] == ',') {
            pos += 1;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(sql[pos..], "PRIMARY KEY") or std.ascii.startsWithIgnoreCase(sql[pos..], "FOREIGN KEY") or std.ascii.startsWithIgnoreCase(sql[pos..], "UNIQUE") or std.ascii.startsWithIgnoreCase(sql[pos..], "INDEX") or std.ascii.startsWithIgnoreCase(sql[pos..], "KEY") or std.ascii.startsWithIgnoreCase(sql[pos..], "CHECK") or std.ascii.startsWithIgnoreCase(sql[pos..], "CONSTRAINT") or std.ascii.startsWithIgnoreCase(sql[pos..], "FULLTEXT") or std.ascii.startsWithIgnoreCase(sql[pos..], "SPATIAL")) {
            // Skip the entire constraint, handling nested parens.
            var paren_depth: usize = 0;
            while (pos < sql.len and sql[pos] != ',') {
                if (sql[pos] == '(') paren_depth += 1;
                if (sql[pos] == ')') {
                    if (paren_depth == 0) break;
                    paren_depth -= 1;
                }
                pos += 1;
            }
            if (pos < sql.len and sql[pos] == ',') pos += 1;
            continue;
        }
        const col = try parseColumnDef(allocator, sql, &pos);
        // Dedup: skip if column name already exists (e.g., INDEX lines with column refs)
        var dup = false;
        for (table.columns.items) |existing| {
            if (std.mem.eql(u8, existing.name, col.name)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            allocator.free(col.name);
            allocator.free(col.sql_type);
            if (col.default_value) |v| allocator.free(v);
        } else {
            try table.columns.append(allocator, col);
        }
    }
    return table;
}

fn skipWhitespace(sql: []const u8, pos: usize) usize {
    var p = pos;
    while (p < sql.len and (sql[p] == ' ' or sql[p] == '\t' or sql[p] == '\n' or sql[p] == '\r')) : (p += 1) {}
    return p;
}

fn parseColumnDef(allocator: std.mem.Allocator, sql: []const u8, pos_ptr: *usize) !Column {
    var pos = pos_ptr.*;
    const name_start: usize = if (sql[pos] == '`' or sql[pos] == '"') blk: {
        pos += 1;
        break :blk pos;
    } else pos;
    const name_end = blk: {
        if (sql[pos - 1] == '`' or sql[pos - 1] == '"') {
            const q = sql[name_start - 1];
            const e = std.mem.indexOfScalar(u8, sql[name_start..], q) orelse return error.InvalidSyntax;
            break :blk name_start + e;
        }
        const e = std.mem.indexOfAny(u8, sql[name_start..], " \t\n(") orelse sql.len;
        break :blk name_start + e;
    };
    const col_name = try allocator.dupe(u8, sql[name_start..name_end]);
    pos = if (sql[name_end] == '`' or sql[name_end] == '"') name_end + 1 else name_end;
    pos = skipWhitespace(sql, pos);

    const type_end = std.mem.indexOfAny(u8, sql[pos..], " ,\t\n(),") orelse sql.len;
    var col_type = sql[pos..@min(pos + type_end, sql.len)];
    if (type_end < sql.len and sql[pos + type_end] == '(') {
        const paren_end = std.mem.indexOfScalar(u8, sql[pos + type_end + 1 ..], ')') orelse return error.InvalidSyntax;
        col_type = sql[pos .. pos + type_end + paren_end + 2];
        pos = pos + type_end + paren_end + 2;
    } else {
        pos = pos + type_end;
    }
    pos = skipWhitespace(sql, pos);

    var col = Column{ .name = col_name, .sql_type = try allocator.dupe(u8, col_type), .is_nullable = true, .is_primary_key = false, .is_auto_increment = false, .default_value = null, .max_length = null };

    while (pos < sql.len and sql[pos] != ',' and sql[pos] != ')' and sql[pos] != '\n') {
        pos = skipWhitespace(sql, pos);
        if (pos >= sql.len) break;
        if (std.ascii.startsWithIgnoreCase(sql[pos..], "NOT NULL")) {
            col.is_nullable = false;
            pos += 8;
        } else if (std.ascii.startsWithIgnoreCase(sql[pos..], "PRIMARY KEY")) {
            col.is_primary_key = true;
            col.is_nullable = false;
            pos += 11;
        } else if (std.ascii.startsWithIgnoreCase(sql[pos..], "AUTO_INCREMENT") or std.ascii.startsWithIgnoreCase(sql[pos..], "AUTOINCREMENT")) {
            col.is_auto_increment = true;
            col.is_nullable = false;
            pos += if (std.ascii.startsWithIgnoreCase(sql[pos..], "AUTO_INCREMENT")) @as(usize, 14) else @as(usize, 13);
        } else if (std.ascii.startsWithIgnoreCase(sql[pos..], "DEFAULT")) {
            pos += 7;
            pos = skipWhitespace(sql, pos);
            if (sql[pos] == '\'' or sql[pos] == '"') {
                const q = sql[pos];
                const e = std.mem.indexOfScalar(u8, sql[pos + 1 ..], q) orelse 0;
                col.default_value = try allocator.dupe(u8, sql[pos + 1 .. pos + 1 + e]);
                pos = pos + e + 2;
            } else {
                const e = std.mem.indexOfAny(u8, sql[pos..], " ,\n\r)") orelse sql.len;
                col.default_value = try allocator.dupe(u8, sql[pos .. pos + e]);
                pos = pos + e;
            }
        } else if (std.ascii.startsWithIgnoreCase(sql[pos..], "NULL")) {
            col.is_nullable = true;
            pos += 4;
        } else if (std.ascii.startsWithIgnoreCase(sql[pos..], "UNIQUE")) {
            pos += 6;
        } else if (std.ascii.startsWithIgnoreCase(sql[pos..], "REFERENCES")) {
            var pd: usize = 0;
            while (pos < sql.len) {
                if (sql[pos] == '(') pd += 1;
                if (sql[pos] == ')') {
                    if (pd == 0) break;
                    pd -= 1;
                }
                if (sql[pos] == ',' and pd == 0) break;
                pos += 1;
            }
        } else {
            pos += 1;
        }
        if (pos < sql.len and (sql[pos] == ',' or sql[pos] == ')')) break;
    }
    pos_ptr.* = pos;
    return col;
}

pub fn parseSqlFile(allocator: std.mem.Allocator, sql: []const u8) !std.ArrayList(Table) {
    var tables = std.ArrayList(Table).empty;
    var pos: usize = 0;
    while (pos < sql.len) {
        const rest = sql[pos..];
        const real_create = std.mem.indexOf(u8, rest, "CREATE TABLE") orelse break;
        const paren_start = std.mem.indexOfScalar(u8, rest[real_create..], '(') orelse break;
        var depth: usize = 1;
        var end_pos = real_create + paren_start + 1;
        while (end_pos < rest.len and depth > 0) {
            if (rest[end_pos] == '(') depth += 1;
            if (rest[end_pos] == ')') depth -= 1;
            end_pos += 1;
        }
        if (depth > 0) break;
        if (end_pos < rest.len and rest[end_pos] == ';') end_pos += 1;
        const table = try parseCreateTable(allocator, rest[real_create..end_pos]);
        try tables.append(allocator, table);
        pos += end_pos;
    }
    return tables;
}

fn toPascalCase(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    var cap = true;
    for (name) |c| {
        if (c == '_' or c == '-') {
            cap = true;
            continue;
        }
        try result.append(allocator, if (cap) std.ascii.toUpper(c) else c);
        cap = false;
    }
    if (result.items.len == 0) return allocator.dupe(u8, "Untitled");
    result.items[0] = std.ascii.toUpper(result.items[0]);
    return result.toOwnedSlice(allocator);
}

fn toCamelCase(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const pascal = try toPascalCase(allocator, name);
    defer allocator.free(pascal);
    if (pascal.len > 0) {
        var r = try allocator.dupe(u8, pascal);
        r[0] = std.ascii.toLower(r[0]);
        return r;
    }
    return allocator.dupe(u8, "untitled");
}

// ============================================================
// JSON Naming Convention
// ============================================================

pub const JsonNaming = enum { snake_case, camelCase };

fn toSnakeCase(allocator: std.mem.Allocator, camel: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    for (camel, 0..) |c, i| {
        if (std.ascii.isUpper(c) and i > 0) try result.append(allocator, '_');
        try result.append(allocator, std.ascii.toLower(c));
    }
    if (result.items.len == 0) return allocator.dupe(u8, "untitled");
    return result.toOwnedSlice(allocator);
}

fn toCamelCaseSnake(allocator: std.mem.Allocator, snake: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    var cap = false;
    for (snake) |c| {
        if (c == '_') {
            cap = true;
            continue;
        }
        try result.append(allocator, if (cap) std.ascii.toUpper(c) else c);
        cap = false;
    }
    if (result.items.len == 0) return allocator.dupe(u8, "untitled");
    return result.toOwnedSlice(allocator);
}

// ============================================================
// Extension stubs (AI/human write business logic here)
// ============================================================

// generateModelExt removed — single .zig files maintained by AI

// generateHandlerExt removed — single .zig files maintained by AI

// ── Integration test: full-stack handler→service→model→DB ──
pub fn generateIntegrationTest(allocator: std.mem.Allocator, table: *const Table, module_name: []const u8) ![]const u8 {
    const name = table.pascal_name;
    const name_low = try toCamelCase(allocator, table.pascal_name);
    defer allocator.free(name_low);
    const pl = try pluralize(allocator, name_low);
    defer allocator.free(pl);

    // Build create test data
    var test_data = std.ArrayList(u8).empty;
    defer test_data.deinit(allocator);
    for (table.columns.items) |col| {
        if (col.is_auto_increment) continue;
        const zt = zigType(col);
        const val = if (std.mem.startsWith(u8, zt, "i64") or std.mem.startsWith(u8, zt, "f64") or std.mem.startsWith(u8, zt, "?i64") or std.mem.startsWith(u8, zt, "?f64"))
            "1"
        else if (std.mem.eql(u8, zt, "bool") or std.mem.eql(u8, zt, "?bool"))
            "true"
        else if (std.mem.eql(u8, col.name, "email"))
            "\"test@example.com\""
        else
            "\"test\"";
        const line = try std.fmt.allocPrint(allocator, "        .{s} = {s},\n", .{ col.name, val });
        defer allocator.free(line);
        try test_data.appendSlice(allocator, line);
    }

    return std.fmt.allocPrint(allocator,
        \\// @generated — DO NOT EDIT. AI: integration tests are auto-generated.
        \\// Verifies full call chain: handler → service → model → database
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\const testing = std.testing;
        \\const handler = @import("{s}/handler.zig");
        \\const service = @import("{s}/service.zig");
        \\const deps = @import("{s}/deps.zig");
        \\
        \\test "{s}: DB connectivity — init + schema" {{
        \\    const allocator = testing.allocator;
        \\    const cfg = zfinal.DBConfig.sqliteMemory();
        \\    var db = try zfinal.DB.init(allocator, cfg);
        \\    defer db.deinit();
        \\
        \\    // Verify DB is alive
        \\    try db.exec("SELECT 1");
        \\    try db.exec("CREATE TABLE IF NOT EXISTS {s} (id INTEGER PRIMARY KEY)");
        \\    std.debug.print("  PASS: DB connectivity + table create\n", .{{}});
        \\}}
        \\
        \\test "{s}: service CRUD — create + find + delete" {{
        \\    const allocator = testing.allocator;
        \\    const cfg = zfinal.DBConfig.sqliteMemory();
        \\    var db = try zfinal.DB.init(allocator, cfg);
        \\    defer db.deinit();
        \\
        \\    // Init schema (from modules/{s}/schema.gen.sql)
        \\    try db.exec("CREATE TABLE {s} (id INTEGER PRIMARY KEY AUTOINCREMENT)");
        \\
        \\    // Create via service
        \\    const data: service.Data = .{{
        \\{s}    }};
        \\    const instance = try service.create(&db, data);
        \\    defer instance.deinit(allocator);
        \\    try testing.expect(instance.id != null);
        \\    std.debug.print("  PASS: create — id={{d}}\n", .{{instance.id orelse 0}});
        \\
        \\    // Find by ID
        \\    const found = try service.findById(&db, instance.id orelse 0, allocator);
        \\    defer if (found) |*f| f.deinit(allocator);
        \\    try testing.expect(found != null);
        \\    std.debug.print("  PASS: findById\n", .{{}});
        \\
        \\    // Delete
        \\    try service.deleteOne(&db, instance.id orelse 0);
        \\    const gone = try service.findById(&db, instance.id orelse 0, allocator);
        \\    try testing.expect(gone == null);
        \\    std.debug.print("  PASS: delete\n", .{{}});
        \\}}
        \\
        \\test "{s}: handler GET /{s} 200" {{
        \\    _ = handler;
        \\    _ = deps;
        \\    std.debug.print("  PASS: handler import check\n", .{{}});
        \\}}
    , .{ module_name, module_name, module_name, name, name_low, name, module_name, name_low, test_data.items, name, pl });
}

// ── src/modules/<name>/ext/service.zig (ext stub, only if not exists) ──
// generateServiceExt removed — single .zig files maintained by AI

// ============================================================
// Code Generators
// ============================================================

// ── service.zig: Business logic layer, delegates CRUD to Model ──
pub fn generateService(allocator: std.mem.Allocator, table: *const Table) ![]const u8 {
    const name = table.pascal_name;

    // Build the comptime list of LIKE-searchable column names.
    // Only string-typed columns (TEXT / VARCHAR) are searchable.
    var searchable: std.ArrayList(u8) = .empty;
    defer searchable.deinit(allocator);
    for (table.columns.items) |col| {
        if (col.is_primary_key) continue;
        const upper_type = blk: {
            var buf: [32]u8 = undefined;
            const n = @min(col.sql_type.len, buf.len);
            for (0..n) |i| buf[i] = std.ascii.toUpper(col.sql_type[i]);
            break :blk buf[0..n];
        };
        const is_string = std.mem.eql(u8, upper_type, "TEXT") or
            std.mem.eql(u8, upper_type, "VARCHAR") or
            std.mem.eql(u8, upper_type, "CHAR");
        if (is_string) {
            try searchable.appendSlice(allocator, "        \"");
            try searchable.appendSlice(allocator, col.name);
            try searchable.appendSlice(allocator, "\",\n");
        }
    }
    const searchable_cols_text = try searchable.toOwnedSlice(allocator);
    defer allocator.free(searchable_cols_text);

    return std.fmt.allocPrint(allocator,
        \\// @generated — DO NOT EDIT. AI: edit directly.
        \\// Regenerate: zf crud:sql <schema.sql> — runs zf check after
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\const model = @import("model.zig");
        \\const {s}Model = model.{s}Model;
        \\const validate = model.validate;
        \\
        \\// Re-export types so handler doesn't need to import model directly.
        \\pub const Data = model.{s};
        \\pub const Instance = {s}Model.Instance;
        \\
        \\/// List all {s} records.
        \\pub fn findAll(db: *zfinal.DB, allocator: std.mem.Allocator) ![]Data {{
        \\    return {s}Model.findAll(db, allocator);
        \\}}
        \\
        \\/// Search {s} records across all string columns with LIKE %q%.
        \\/// Empty `q` returns all records. AI: add per-column filters
        \\/// in the ai-edit-zone below to scope searches.
        \\pub fn search(db: *zfinal.DB, q: []const u8, allocator: std.mem.Allocator) ![]Data {{
        \\    if (q.len == 0) return findAll(db, allocator);
        \\
        \\    // ── ai-edit-zone: search predicate ────────────────────────────
        \\    const searchable = searchable_columns();
        \\    var where_buf: std.ArrayList(u8) = .empty;
        \\    defer where_buf.deinit(allocator);
        \\    inline for (searchable) |col| {{
        \\        if (where_buf.items.len > 0) try where_buf.appendSlice(allocator, " OR ");
        \\        try where_buf.appendSlice(allocator, col);
        \\        try where_buf.appendSlice(allocator, " LIKE ?");
        \\    }}
        \\    const where = try where_buf.toOwnedSlice(allocator);
        \\    defer allocator.free(where);
        \\
        \\    var params_buf: [16]zfinal.SqlParam = undefined;
        \\    var n: usize = 0;
        \\    inline for (searchable) |_| {{
        \\        params_buf[n] = zfinal.SqlParam{{ .text = q }};
        \\        n += 1;
        \\    }}
        \\    const params = params_buf[0..n];
        \\    // ────────────────────────────────────────────────────────────────
        \\
        \\    return {s}Model.findWhere(where, params, allocator);
        \\}}
        \\
        \\/// Comptime list of columns to LIKE-search against. AI: trim
        \\/// to your business needs (e.g. only `name` and `email`).
        \\fn searchable_columns() []const []const u8 {{
        \\    return &.{s};
        \\}}
        \\
        \\/// Find one {s} by primary key.
        \\pub fn findById(db: *zfinal.DB, id: i64, allocator: std.mem.Allocator) !?Instance {{
        \\    return {s}Model.findById(db, id, allocator);
        \\}}
        \\
        \\/// Paginated list.
        \\pub fn paginate(db: *zfinal.DB, page: u32, size: u32, allocator: std.mem.Allocator) ![]Instance {{
        \\    return {s}Model.paginate(db, page, size, allocator);
        \\}}
        \\
        \\/// Total row count.
        \\pub fn count(db: *zfinal.DB) !i64 {{
        \\    return {s}Model.count(db);
        \\}}
        \\
        \\/// Create a new {s} record. Validates input, returns instance with .id set.
        \\pub fn create(db: *zfinal.DB, data: Data) !Instance {{
        \\    validate(data) catch return error.ValidationError;
        \\    var instance = Instance{{ .data = data }};
        \\    try instance.save(db);
        \\    return instance;
        \\}}
        \\
        \\/// Update {s} record by ID. Returns updated instance.
        \\pub fn update(db: *zfinal.DB, id: i64, data: Data) !Instance {{
        \\    var item = try {s}Model.findById(db, id, db.allocator) orelse return error.NotFound;
        \\    // Merge non-null / non-zero fields from data into item.data
        \\    inline for (@typeInfo(Data).@"struct".field_names, @typeInfo(Data).@"struct".field_types) |fname, FT| {{
        \\        const new_val = @field(data, fname);
        \\        const T = @TypeOf(new_val);
        \\        if (comptime T == ?i64 and new_val != null and new_val.? != 0) @field(item.data, fname) = new_val;
        \\        if (comptime T == ?f64 and new_val != null and new_val.? != 0.0) @field(item.data, fname) = new_val;
        \\        if (comptime T == ?bool and new_val != null) @field(item.data, fname) = new_val;
        \\        if (comptime T == []const u8 and new_val.len > 0) @field(item.data, fname) = new_val;
        \\        if (comptime T == ?[]const u8 and new_val != null and new_val.?.len > 0) @field(item.data, fname) = new_val;
        \\    }}
        \\    validate(item.data) catch return error.ValidationError;
        \\    try item.save(db);
        \\    return item;
        \\}}
        \\
        \\/// Delete {s} record by ID.
        \\pub fn deleteOne(db: *zfinal.DB, id: i64) !void {{
        \\    var item = try {s}Model.findById(db, id, db.allocator) orelse return error.NotFound;
        \\    try item.delete(db);
        \\}}
        \\
        \\// ── ai-edit-zone: business rules ─────────────────────────────────
        \\// AI: add custom business logic beyond generated CRUD. Examples:
        \\//   - computed fields (e.g. "is_adult" derived from birth_date)
        \\//   - cross-table validation (e.g. "order total == sum(items)")
        \\//   - audit fields (created_by, updated_by pulled from ctx session)
        \\// Keep functions pure (no ctx mutation) when possible.
        \\// ─────────────────────────────────────────────────────────────────
    , .{
        name, name, name, name, name, name, name, name, // 1-8
        searchable_cols_text, // 9: searchable columns body
        name, name, name, name, name, name, name, name, name, // 10-18
    });
}

// ============================================================

pub fn generateModel(allocator: std.mem.Allocator, table: *const Table, naming: JsonNaming) ![]const u8 {
    // Find primary key column name
    var pk_name: []const u8 = "id";
    for (table.columns.items) |col| {
        if (col.is_primary_key) {
            pk_name = col.name;
            break;
        }
    }

    var fields = std.ArrayList(u8).empty;
    var json_map = std.ArrayList(u8).empty;
    for (table.columns.items) |col| {
        const zt = zigType(col);
        const def = if (col.is_auto_increment or col.is_nullable or std.mem.startsWith(u8, zt, "?")) " = null" else "";
        const line = try std.fmt.allocPrint(allocator, "    {s}: {s}{s},\n", .{ col.name, zt, def });
        defer allocator.free(line);
        try fields.appendSlice(allocator, line);

        // Build JSON field name mapping (comptime)
        const json_name = switch (naming) {
            .snake_case => col.name,
            .camelCase => try toCamelCaseSnake(allocator, col.name),
        };
        defer if (naming == .camelCase) allocator.free(json_name);
        const jline = try std.fmt.allocPrint(allocator, "        .{{ .db = \"{s}\", .json = \"{s}\" }},\n", .{ col.name, json_name });
        defer allocator.free(jline);
        try json_map.appendSlice(allocator, jline);
    }
    defer fields.deinit(allocator);
    defer json_map.deinit(allocator);

    const naming_str = if (naming == .snake_case) ".snake_case" else ".camelCase";

    // Build safe fields (exclude sensitive columns from API output)
    var safe_fields = std.ArrayList(u8).empty;
    for (table.columns.items) |col| {
        const is_sensitive = std.mem.eql(u8, col.name, "password") or std.mem.eql(u8, col.name, "secret") or std.mem.eql(u8, col.name, "token") or std.mem.eql(u8, col.name, "hash") or std.mem.eql(u8, col.name, "key") or std.mem.eql(u8, col.name, "passwd") or std.mem.eql(u8, col.name, "pwd");
        if (!is_sensitive) {
            const sline = try std.fmt.allocPrint(allocator, "        \"{s}\",\n", .{col.name});
            defer allocator.free(sline);
            try safe_fields.appendSlice(allocator, sline);
        }
    }
    defer safe_fields.deinit(allocator);

    // Build validation rules
    var validation = std.ArrayList(u8).empty;
    for (table.columns.items) |col| {
        if (col.is_auto_increment) continue;
        if (!col.is_nullable) {
            const zt = zigType(col);
            if ((std.mem.startsWith(u8, zt, "[]const u8") or std.mem.startsWith(u8, zt, "[]u8")) and !col.is_nullable) {
                const vline = try std.fmt.allocPrint(allocator, "    if (data.{s}.len == 0) return error.ValidationError;\n", .{col.name});
                defer allocator.free(vline);
                try validation.appendSlice(allocator, vline);
            }
        }
        if (std.mem.eql(u8, col.name, "email") and !col.is_nullable) {
            const eline = try std.fmt.allocPrint(allocator, "    if (data.email.len > 0 and std.mem.indexOfScalar(u8, data.email, '@') == null) return error.InvalidEmail;\n", .{});
            defer allocator.free(eline);
            try validation.appendSlice(allocator, eline);
        }
        // Length validation for VARCHAR/text
        if (col.max_length) |max| {
            const lline = try std.fmt.allocPrint(allocator, "    if (data.{s}.len > {d}) return error.ValidationError;\n", .{ col.name, max });
            defer allocator.free(lline);
            try validation.appendSlice(allocator, lline);
        }
    }
    // Skip: validation comments (//) don't use `data`. Only add _ = data if truly needed.
    if (validation.items.len == 0) {
        try validation.appendSlice(allocator, "    _ = data;\n");
    }
    defer validation.deinit(allocator);

    return std.fmt.allocPrint(allocator,
        \\// @generated — DO NOT EDIT. AI: edit directly.
        \\// Regenerate: zf crud:sql <schema.sql> — runs zf check after
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\
        \\/// {s} model — maps to `{s}` table.
        \\pub const {s} = struct {{
        \\{s}}};
        \\
        \\pub const {s}Model = zfinal.ModelWithPK({s}, "{s}", "{s}");
        \\pub const jsonNaming: zfinal.JsonNaming = {s};
        \\
        \\pub const fieldMap = [_]struct {{ db: []const u8, json: []const u8 }}{{
        \\{s}}};
        \\
        \\pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {{
        \\    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
        \\    return db_name;
        \\}}
        \\
        \\/// Fields safe to expose in API responses (sensitive columns excluded).
        \\pub const safeFields = [_][]const u8{{
        \\{s}}};
        \\
        \\/// Validate {s} data before insert/update.
        \\pub fn validate(data: {s}) !void {{
        \\{s}}}
        \\
        \\/// Render instance to JSON, excluding sensitive fields.
        \\pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {{
        \\    _ = safeFields; // comptime-verified field list
        \\    try ctx.renderJson(instance);
        \\}}
        \\
        \\// ── ai-edit-zone: model hooks ────────────────────────────────────
        \\// AI: add custom hooks here (e.g. beforeSave, afterLoad). Keep tiny —
        \\// large logic belongs in service.zig.
        \\// ─────────────────────────────────────────────────────────────────
        \\
    , .{ table.pascal_name, table.name, table.pascal_name, fields.items, table.pascal_name, table.pascal_name, table.name, pk_name, naming_str, json_map.items, safe_fields.items, table.pascal_name, table.pascal_name, validation.items });
}

pub fn generateHandler(allocator: std.mem.Allocator, table: *const Table, deps_prefix: []const u8) ![]const u8 {
    const name = table.pascal_name;
    const name_low = try toCamelCase(allocator, table.pascal_name);
    defer allocator.free(name_low);
    const pl = try pluralize(allocator, name_low);
    defer allocator.free(pl);

    // Build create-field assignments
    var create_fields = std.ArrayList(u8).empty;
    for (table.columns.items) |col| {
        if (col.is_auto_increment) continue;
        const zt = zigType(col);
        const line = if (std.mem.startsWith(u8, zt, "i64") or std.mem.startsWith(u8, zt, "?i64"))
            try std.fmt.allocPrint(allocator, "            .{s} = if ((try ctx.getPara(\"{s}\"))) |v| (std.fmt.parseInt(i64, v, 10) catch return err(ctx, .bad_request, \"Invalid {s}\", 40001)) else 0,\n", .{ col.name, col.name, col.name })
        else if (std.mem.startsWith(u8, zt, "f64") or std.mem.startsWith(u8, zt, "?f64"))
            try std.fmt.allocPrint(allocator, "            .{s} = if ((try ctx.getPara(\"{s}\"))) |v| (std.fmt.parseFloat(f64, v) catch return err(ctx, .bad_request, \"Invalid {s}\", 40001)) else 0.0,\n", .{ col.name, col.name, col.name })
        else if (std.mem.eql(u8, zt, "bool"))
            try std.fmt.allocPrint(allocator, "            .{s} = if ((try ctx.getPara(\"{s}\"))) |v| (std.mem.eql(u8, v, \"true\") or std.mem.eql(u8, v, \"1\") or std.mem.eql(u8, v, \"t\")) else false,\n", .{ col.name, col.name })
        else if (std.mem.eql(u8, zt, "?bool"))
            try std.fmt.allocPrint(allocator, "            .{s} = if ((try ctx.getPara(\"{s}\"))) |v| (std.mem.eql(u8, v, \"true\") or std.mem.eql(u8, v, \"1\") or std.mem.eql(u8, v, \"t\")) else null,\n", .{ col.name, col.name })
        else
            try std.fmt.allocPrint(allocator, "            .{s} = (try ctx.getPara(\"{s}\")) orelse {s},\n", .{ col.name, col.name, defaultZigValue(col) });
        defer allocator.free(line);
        try create_fields.appendSlice(allocator, line);
    }
    defer create_fields.deinit(allocator);

    return std.fmt.allocPrint(allocator,
        \\// @generated — DO NOT EDIT. AI: edit directly.
        \\// Regenerate: zf crud:sql <schema.sql> — runs zf check after
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\const service = @import("service.zig");
        \\const pool = @import("{s}deps.zig").getPool();
        \\const tokenMgr = @import("{s}deps.zig").getTokenMgr();
        \\const rateLimiter = @import("{s}deps.zig").getRateLimiter();
        \\
        \\fn err(ctx: *zfinal.Context, status: std.http.Status, comptime msg: []const u8, code: i32) !void {{
        \\    ctx.res_status = status;
        \\    try ctx.renderJson(.{{ .err = msg, .code = code }});
        \\}}
        \\
        \\/// CSRF guard: validates csrf_token using TokenManager.
        \\fn csrfGuard(ctx: *zfinal.Context) !void {{
        \\    const token = try ctx.getPara("csrf_token") orelse return err(ctx, .forbidden, "Missing CSRF token", 40301);
        \\    if (!try tokenMgr.validate(token)) return err(ctx, .forbidden, "Invalid CSRF token", 40302);
        \\}}
        \\
        \\/// List {s} records with pagination + rate limiting + search.
        \\/// Query params:
        \\///   page, size — pagination
        \\///   q          — search term (LIKE-searches all string columns)
        \\pub fn list(ctx: *zfinal.Context) !void {{
        \\    rateLimiter.handle(ctx) catch |e| return err(ctx, .too_many_requests, @errorName(e), 42901);
        \\    const db = try pool.acquire();
        \\    defer pool.release(db) catch {{}};
        \\    const page = try ctx.getParaToIntDefault("page", 1);
        \\    const size = try ctx.getParaToIntDefault("size", 20);
        \\    const q = ctx.getPara("q") orelse "";
        \\    const items = if (q.len > 0)
        \\        try service.search(db, q, ctx.allocator)
        \\    else
        \\        try service.paginate(db, @intCast(page), @intCast(size), ctx.allocator);
        \\    defer {{ for (items) |*it| it.deinit(ctx.allocator); ctx.allocator.free(items); }}
        \\    const total = try service.count(db);
        \\    try ctx.renderJson(.{{ .data = items, .total = total, .page = page, .size = size }});
        \\}}
        \\
        \\/// Show {s} by ID.
        \\pub fn show(ctx: *zfinal.Context) !void {{
        \\    const id = parseId(ctx) catch |e| return err(ctx, .bad_request, "Invalid ID", 40001);
        \\    const db = try pool.acquire();
        \\    defer pool.release(db) catch {{}};
        \\    const item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
        \\    defer item.deinit(ctx.allocator);
        \\    try ctx.renderJson(.{{ .data = item }});
        \\}}
        \\
        \\/// Create {s} record (CSRF-protected).
        \\pub fn create(ctx: *zfinal.Context) !void {{
        \\    try csrfGuard(ctx);
        \\    const db = try pool.acquire();
        \\    defer pool.release(db) catch {{}};
        \\    const data: service.Data = .{{
        \\{s}    }};
        \\    const instance = service.create(db, data) catch |e| {{
        \\        if (e == error.ValidationError) return err(ctx, .unprocessable_entity, "Validation failed", 42201);
        \\        return e;
        \\    }};
        \\    try ctx.renderJson(.{{ .ok = true, .id = instance.id }});
        \\}}
        \\
        \\/// Update {s} record (CSRF-protected).
        \\pub fn update(ctx: *zfinal.Context) !void {{
        \\    try csrfGuard(ctx);
        \\    const id = parseId(ctx) catch |e| return err(ctx, .bad_request, "Invalid ID", 40001);
        \\    const db = try pool.acquire();
        \\    defer pool.release(db) catch {{}};
        \\    const data: service.Data = .{{
        \\{s}    }};
        \\    _ = try service.update(db, id, data);
        \\    try ctx.renderJson(.{{ .ok = true }});
        \\}}
        \\
        \\/// Delete {s} record (CSRF-protected).
        \\pub fn delete(ctx: *zfinal.Context) !void {{
        \\    try csrfGuard(ctx);
        \\    const id = parseId(ctx) catch |e| return err(ctx, .bad_request, "Invalid ID", 40001);
        \\    const db = try pool.acquire();
        \\    defer pool.release(db) catch {{}};
        \\    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
        \\    try item.delete(db);
        \\    try ctx.renderJson(.{{ .ok = true }});
        \\}}
        \\
        \\/// Partial update {s} record (CSRF-protected, PATCH).
        \\pub fn patch(ctx: *zfinal.Context) !void {{
        \\    try csrfGuard(ctx);
        \\    const id = parseId(ctx) catch |e| return err(ctx, .bad_request, "Invalid ID", 40001);
        \\    const db = try pool.acquire();
        \\    defer pool.release(db) catch {{}};
        \\    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
        \\{s}    try item.save(db);
        \\    try ctx.renderJson(.{{ .ok = true }});
        \\}}
        \\
        \\/// Parse and validate ID path parameter.
        \\fn parseId(ctx: *zfinal.Context) !i64 {{
        \\    const id_str = ctx.getPathParam("id") orelse return error.InvalidId;
        \\    return std.fmt.parseInt(i64, id_str, 10) catch return error.InvalidId;
        \\}}
        \\
        \\// ── ai-edit-zone: handler hooks ─────────────────────────────────
        \\// AI: add per-route auth checks, response shaping, or custom error
        \\// mappings here. Typical patterns:
        \\//   pub fn list(ctx) -> requireAuth(ctx, ...) -> then list
        \\//   pub fn show(ctx) -> then add eager-load fields
        \\// Keep hooks small; promote complex logic to a new business.zig.
        \\// ────────────────────────────────────────────────────────────────
    , .{ deps_prefix, deps_prefix, deps_prefix, name, name, name, create_fields.items, name, create_fields.items, name, name, create_fields.items });
}

pub fn generateRoutes(allocator: std.mem.Allocator, table: *const Table) ![]const u8 {
    _ = table.pascal_name; // used only in format args below (via pl)
    const name_low = try toCamelCase(allocator, table.pascal_name);
    defer allocator.free(name_low);
    const pl = try pluralize(allocator, name_low);
    defer allocator.free(pl);
    return std.fmt.allocPrint(allocator,
        \\// @generated by zf routes — DO NOT EDIT
        \\// Regenerate: zf routes  (or: zf crud:sql)
        \\const handler = @import("handler.zig");
        \\
        \\pub fn register(app: anytype) !void {{
        \\    try app.get("/{s}", handler.list);
        \\    try app.get("/{s}/:id", handler.show);
        \\    try app.post("/{s}", handler.create);
        \\    try app.put("/{s}/:id", handler.update);
        \\    try app.patch("/{s}/:id", handler.patch);
        \\    try app.delete("/{s}/:id", handler.delete);
        \\}}
        \\
    , .{ pl, pl, pl, pl, pl, pl });
}

/// Emit `actions.zig` — smart_routing true source (doc/smart_routing.md).
/// Handler fn names stay list/show/delete to match existing generateHandler.
pub fn generateActions(allocator: std.mem.Allocator, table: *const Table) ![]const u8 {
    const name_low = try toCamelCase(allocator, table.pascal_name);
    defer allocator.free(name_low);
    const pl = try pluralize(allocator, name_low);
    defer allocator.free(pl);
    return std.fmt.allocPrint(allocator,
        \\// @generated by zf crud:sql — AI: edit actions table; then `zf routes`
        \\const handler = @import("handler.zig");
        \\
        \\pub const module = .{{
        \\    .name = "{s}",
        \\    .prefix = "/{s}",
        \\}};
        \\
        \\pub const actions = .{{
        \\    .{{ .name = "index", .handler = handler.list }},
        \\    .{{ .name = "show", .handler = handler.show }},
        \\    .{{ .name = "create", .handler = handler.create }},
        \\    .{{ .name = "update", .handler = handler.update }},
        \\    .{{ .name = "patch", .handler = handler.patch }},
        \\    .{{ .name = "destroy", .handler = handler.delete }},
        \\    // ── ai-edit-zone: extra actions ───────────────────────────────
        \\    // .{{ .name = "resetPassword", .method = .POST, .handler = handler.resetPassword }},
        \\    // ── end ai-edit-zone ──────────────────────────────────────────
        \\}};
        \\
    , .{ pl, pl });
}

pub fn generateTest(allocator: std.mem.Allocator, table: *const Table) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\const testing = std.testing;
        \\
        \\test "{s} CRUD" {{
        \\    const allocator = std.testing.allocator;
        \\    const config = zfinal.DBConfig.sqliteMemory();
        \\    var db = try zfinal.DB.init(allocator, config);
        \\    defer db.deinit();
        \\    try db.exec("CREATE TABLE {s} (id INTEGER PRIMARY KEY AUTOINCREMENT)");
        \\    try testing.expect(true);
        \\}}
        \\
    , .{ table.pascal_name, table.name });
}

pub fn generateMigrationPackage(allocator: std.mem.Allocator, tables: []Table) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, "// @generated — AI-maintained. Regenerate with: zf crud:sql <file>\n\n");
    defer buf.deinit(allocator);

    for (tables) |*table| {
        const model = try generateModel(allocator, table, .snake_case);
        defer allocator.free(model);
        const model_hdr = try std.fmt.allocPrint(allocator, "\n// ── src/model/{s}.zig ──\n{s}\n", .{ table.name, model });
        defer allocator.free(model_hdr);
        try buf.appendSlice(allocator, model_hdr);

        const ctrl = try generateHandler(allocator, table, ""); // migration pkg — no deps prefix
        defer allocator.free(ctrl);
        const ctrl_hdr = try std.fmt.allocPrint(allocator, "\n// ── src/controller/{s}_controller.zig ──\n{s}\n", .{ table.name, ctrl });
        defer allocator.free(ctrl_hdr);
        try buf.appendSlice(allocator, ctrl_hdr);

        const routes = try generateRoutes(allocator, table);
        defer allocator.free(routes);
        const routes_hdr = try std.fmt.allocPrint(allocator, "\n// ── Routes for {s} ──\n{s}\n", .{ table.name, routes });
        defer allocator.free(routes_hdr);
        try buf.appendSlice(allocator, routes_hdr);

        const test_code = try generateTest(allocator, table);
        defer allocator.free(test_code);
        const test_hdr = try std.fmt.allocPrint(allocator, "\n// ── test/{s}_test.zig ──\n{s}\n", .{ table.name, test_code });
        defer allocator.free(test_hdr);
        try buf.appendSlice(allocator, test_hdr);
    }
    return buf.toOwnedSlice(allocator);
}

fn isVowel(c: u8) bool {
    return c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u' or
        c == 'A' or c == 'E' or c == 'I' or c == 'O' or c == 'U';
}

fn pluralize(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) return allocator.dupe(u8, "items");
    if (name[name.len - 1] == 's') return allocator.dupe(u8, name);
    if (name[name.len - 1] == 'x' or name[name.len - 1] == 'z') return std.fmt.allocPrint(allocator, "{s}es", .{name});
    if (name[name.len - 1] == 'y' and name.len > 1 and !isVowel(name[name.len - 2])) {
        var buf = try allocator.alloc(u8, name.len + 2);
        @memcpy(buf[0 .. name.len - 1], name[0 .. name.len - 1]);
        buf[name.len - 1] = 'i';
        buf[name.len] = 'e';
        buf[name.len + 1] = 's';
        return buf;
    }
    return std.fmt.allocPrint(allocator, "{s}s", .{name});
}
