//! Controlled business skills for AI Agents.
//!
//! - `db.query` — read-only parameterized SELECT, row-capped, fragment-safe;
//! - `entity.lookup` / `entity.list` — whitelist-only table access, optional tenant scope.
//!
//! Set `SkillContext.userdata = *BusinessCtx` (holds `*DB` + entity specs).

const std = @import("std");
const DB = @import("../db/db.zig").DB;
const ResultSet = @import("../db/result.zig").ResultSet;
const Row = @import("../db/result.zig").Row;
const Cell = @import("../db/result.zig").Cell;
const SqlParam = @import("../db/sql_param.zig").SqlParam;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;

pub const max_rows: usize = 100;
pub const default_limit: usize = 20;

pub const EntitySpec = struct {
    name: []const u8,
    table: []const u8,
    pk: []const u8 = "id",
    tenant_column: ?[]const u8 = null,
};

/// Capability bundle. Keep alive for the registry lifetime; point
/// `SkillContext.userdata` here before dispatch.
pub const BusinessCtx = struct {
    db: *DB,
    entities: []const EntitySpec = &.{},
    /// When true (default) and `SkillContext.tenant_id` is set, `db.query` SQL
    /// must mention the tenant column name (or set `require_tenant_on_query=false`).
    require_tenant_on_query: bool = true,
    /// Identifier that must appear in `db.query` SQL when tenant is set (default `tenant_id`).
    query_tenant_column: []const u8 = "tenant_id",
};

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
    }
    return true;
}

/// Reject string literals / comments / `;` so values must use `?` + args.
pub fn validateSqlFragment(fragment: []const u8) error{UnsafeSqlFragment}!void {
    if (fragment.len > 4096) return error.UnsafeSqlFragment;
    var i: usize = 0;
    while (i < fragment.len) : (i += 1) {
        switch (fragment[i]) {
            '\'', '"', ';', 0 => return error.UnsafeSqlFragment,
            '-' => if (i + 1 < fragment.len and fragment[i + 1] == '-') return error.UnsafeSqlFragment,
            '/' => if (i + 1 < fragment.len and fragment[i + 1] == '*') return error.UnsafeSqlFragment,
            else => {},
        }
    }
}

fn bizFrom(ctx: *SkillContext) !*BusinessCtx {
    return @ptrCast(@alignCast(ctx.userdata orelse return error.BackendNotConfigured));
}

fn jsonToParam(v: std.json.Value) error{InvalidArguments}!SqlParam {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .int = if (b) 1 else 0 },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .real = f },
        .string => |s| .{ .text = s },
        else => error.InvalidArguments,
    };
}

fn readArgs(ctx: *SkillContext, v: ?std.json.Value) ![]SqlParam {
    const arr = (v orelse return &.{}).array;
    const out = try ctx.allocator.alloc(SqlParam, arr.items.len);
    errdefer ctx.allocator.free(out);
    for (arr.items, 0..) |item, i| out[i] = try jsonToParam(item);
    return out;
}

fn cellToJson(cell: Cell, allocator: std.mem.Allocator) !std.json.Value {
    return switch (cell) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .int => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .text => |t| .{ .string = try allocator.dupe(u8, t) },
        .blob => |b| .{ .string = try allocator.dupe(u8, b) },
    };
}

fn rowToJson(row: *const Row, columns: []const []const u8, allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap{};
    errdefer {
        var it = obj.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            switch (e.value_ptr.*) {
                .string => |s| allocator.free(s),
                else => {},
            }
        }
        obj.deinit(allocator);
    }
    const n = @min(columns.len, row.cells.len);
    for (0..n) |i| {
        const key = try allocator.dupe(u8, columns[i]);
        try obj.put(allocator, key, try cellToJson(row.cells[i], allocator));
    }
    return .{ .object = obj };
}

fn findEntity(entities: []const EntitySpec, name: []const u8) ?EntitySpec {
    for (entities) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

fn parseLimit(obj: std.json.ObjectMap) !usize {
    if (obj.get("limit")) |lv| {
        if (lv != .integer) return error.InvalidArguments;
        return @min(@as(usize, @intCast(@max(lv.integer, 1))), max_rows);
    }
    return default_limit;
}

fn dupeZ(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(out[0..s.len], s);
    return out;
}

fn queryToRows(ctx: *SkillContext, db: *DB, sql: []const u8, params: []const SqlParam, limit: usize) !std.json.Value {
    const sql_z = try dupeZ(ctx.allocator, sql);
    defer ctx.allocator.free(sql_z);

    var rs = try db.queryParams(sql_z, params);
    defer rs.deinit();

    var rows = std.json.Array.init(ctx.allocator);
    errdefer {
        for (rows.items) |item| @import("skill.zig").freeValue(ctx.allocator, item);
        rows.deinit();
    }
    var count: usize = 0;
    while (rs.next()) {
        if (count >= limit) break;
        const row = rs.currentRow() orelse continue;
        try rows.append(try rowToJson(row, rs.columns, ctx.allocator));
        count += 1;
    }
    var out = std.json.ObjectMap{};
    try putOwned(&out, ctx.allocator, "rows", .{ .array = rows });
    try putOwned(&out, ctx.allocator, "count", .{ .integer = @intCast(count) });
    return .{ .object = out };
}

pub fn registerBusinessSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "db.query",
        .description = "Run a read-only parameterized SQL SELECT. Use ? placeholders; pass values in args. Row count is capped.",
        .parameters = &.{
            .{ .name = "sql", .type = .string, .description = "SELECT with ? placeholders (no literals, no ;)", .required = true },
            .{ .name = "args", .type = .array, .description = "Values for ? placeholders", .required = false },
            .{ .name = "limit", .type = .number, .description = "Max rows (default 20, cap 100)", .required = false },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const biz = try bizFrom(ctx);
                if (args != .object) return error.InvalidArguments;
                const obj = args.object;
                const sql_v = obj.get("sql") orelse return error.InvalidArguments;
                if (sql_v != .string) return error.InvalidArguments;
                const sql = std.mem.trim(u8, sql_v.string, " \t\r\n");
                if (sql.len < 6 or !std.ascii.eqlIgnoreCase(sql[0..6], "SELECT")) return error.ReadOnlyQueryRequired;
                try validateSqlFragment(sql);

                if (biz.require_tenant_on_query) {
                    if (ctx.tenant_id) |_| {
                        if (std.mem.indexOf(u8, sql, biz.query_tenant_column) == null) {
                            return error.TenantFilterRequired;
                        }
                    }
                }

                const limit = try parseLimit(obj);
                const sql_args = try readArgs(ctx, obj.get("args"));
                defer ctx.allocator.free(sql_args);
                return queryToRows(ctx, biz.db, sql, sql_args, limit);
            }
        }.h,
    });

    try registry.register(.{
        .name = "entity.lookup",
        .description = "Look up one whitelisted entity by primary key",
        .parameters = &.{
            .{ .name = "entity", .type = .string, .description = "Registered entity name", .required = true },
            .{ .name = "id", .type = .string, .description = "Primary key (string or number)", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const biz = try bizFrom(ctx);
                if (args != .object) return error.InvalidArguments;
                const obj = args.object;
                const ent_v = obj.get("entity") orelse return error.InvalidArguments;
                const id_v = obj.get("id") orelse return error.InvalidArguments;
                if (ent_v != .string) return error.InvalidArguments;
                if (id_v != .string and id_v != .integer) return error.InvalidArguments;
                const spec = findEntity(biz.entities, ent_v.string) orelse return error.UnknownEntity;
                if (!isValidIdentifier(spec.table) or !isValidIdentifier(spec.pk)) return error.UnsafeSqlIdentifier;

                var sql_buf = std.ArrayList(u8).empty;
                defer sql_buf.deinit(ctx.allocator);
                try sql_buf.print(ctx.allocator, "SELECT * FROM {s} WHERE {s} = ?", .{ spec.table, spec.pk });

                var params = std.ArrayList(SqlParam).empty;
                defer params.deinit(ctx.allocator);
                try params.append(ctx.allocator, try jsonToParam(id_v));

                if (spec.tenant_column) |tc| {
                    if (ctx.tenant_id) |tid| {
                        if (!isValidIdentifier(tc)) return error.UnsafeSqlIdentifier;
                        try sql_buf.print(ctx.allocator, " AND {s} = ?", .{tc});
                        try params.append(ctx.allocator, .{ .int = tid });
                    }
                }

                const sql_z = try dupeZ(ctx.allocator, sql_buf.items);
                defer ctx.allocator.free(sql_z);
                var rs = try biz.db.queryParams(sql_z, params.items);
                defer rs.deinit();
                if (!rs.next()) return .{ .null = {} };
                const row = rs.currentRow() orelse return .{ .null = {} };
                return rowToJson(row, rs.columns, ctx.allocator);
            }
        }.h,
    });

    try registry.register(.{
        .name = "entity.list",
        .description = "List whitelisted entities with optional equality filters",
        .parameters = &.{
            .{ .name = "entity", .type = .string, .description = "Registered entity name", .required = true },
            .{ .name = "filters", .type = .object, .description = "column → value equality filters", .required = false },
            .{ .name = "limit", .type = .number, .description = "Max rows (default 20, cap 100)", .required = false },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const biz = try bizFrom(ctx);
                if (args != .object) return error.InvalidArguments;
                const obj = args.object;
                const ent_v = obj.get("entity") orelse return error.InvalidArguments;
                if (ent_v != .string) return error.InvalidArguments;
                const spec = findEntity(biz.entities, ent_v.string) orelse return error.UnknownEntity;
                if (!isValidIdentifier(spec.table)) return error.UnsafeSqlIdentifier;

                const limit = try parseLimit(obj);
                var sql_buf = std.ArrayList(u8).empty;
                defer sql_buf.deinit(ctx.allocator);
                try sql_buf.print(ctx.allocator, "SELECT * FROM {s} WHERE 1=1", .{spec.table});

                var params = std.ArrayList(SqlParam).empty;
                defer params.deinit(ctx.allocator);

                if (obj.get("filters")) |fv| {
                    if (fv != .object) return error.InvalidArguments;
                    var it = fv.object.iterator();
                    while (it.next()) |entry| {
                        if (!isValidIdentifier(entry.key_ptr.*)) return error.UnsafeSqlIdentifier;
                        try sql_buf.print(ctx.allocator, " AND {s} = ?", .{entry.key_ptr.*});
                        try params.append(ctx.allocator, try jsonToParam(entry.value_ptr.*));
                    }
                }
                if (spec.tenant_column) |tc| {
                    if (ctx.tenant_id) |tid| {
                        if (!isValidIdentifier(tc)) return error.UnsafeSqlIdentifier;
                        try sql_buf.print(ctx.allocator, " AND {s} = ?", .{tc});
                        try params.append(ctx.allocator, .{ .int = tid });
                    }
                }
                try sql_buf.print(ctx.allocator, " LIMIT {d}", .{limit});
                return queryToRows(ctx, biz.db, sql_buf.items, params.items, limit);
            }
        }.h,
    });
}

test "validateSqlFragment rejects literals and comments" {
    try validateSqlFragment("name = ? AND age > ?");
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("name = 'Alice'"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1; DROP TABLE t"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 -- x"));
}

test "business skills db.query and entity.lookup" {
    const allocator = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;

    var db = try DB.init(allocator, DBConfig.sqliteMemory());
    defer db.destroy();
    try db.exec(
        \\CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, tenant_id INTEGER);
        \\INSERT INTO products (id, name, tenant_id) VALUES (1, 'widget', 7);
        \\INSERT INTO products (id, name, tenant_id) VALUES (2, 'gadget', 8);
    );

    const entities = [_]EntitySpec{
        .{ .name = "product", .table = "products", .pk = "id", .tenant_column = "tenant_id" },
    };
    var biz = BusinessCtx{ .db = db, .entities = &entities };

    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerBusinessSkills(&registry);

    var ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&biz), .tenant_id = 7 };

    var qargs = std.json.ObjectMap{};
    defer qargs.deinit(allocator);
    try qargs.put(allocator, "sql", .{ .string = "SELECT id, name FROM products WHERE tenant_id = ?" });
    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .integer = 7 });
    try qargs.put(allocator, "args", .{ .array = arr });
    const qr = try registry.dispatch("db.query", &ctx, .{ .object = qargs });
    defer @import("skill.zig").freeValue(allocator, qr);
    try std.testing.expectEqual(@as(i64, 1), qr.object.get("count").?.integer);

    var largs = std.json.ObjectMap{};
    defer largs.deinit(allocator);
    try largs.put(allocator, "entity", .{ .string = "product" });
    try largs.put(allocator, "id", .{ .integer = 1 });
    const lr = try registry.dispatch("entity.lookup", &ctx, .{ .object = largs });
    defer @import("skill.zig").freeValue(allocator, lr);
    try std.testing.expectEqualStrings("widget", lr.object.get("name").?.string);

    // Wrong tenant → not found
    var miss = std.json.ObjectMap{};
    defer miss.deinit(allocator);
    try miss.put(allocator, "entity", .{ .string = "product" });
    try miss.put(allocator, "id", .{ .integer = 2 });
    const mr = try registry.dispatch("entity.lookup", &ctx, .{ .object = miss });
    defer @import("skill.zig").freeValue(allocator, mr);
    try std.testing.expect(mr == .null);

    // Cross-tenant SELECT without tenant column → rejected
    var bad = std.json.ObjectMap{};
    defer bad.deinit(allocator);
    try bad.put(allocator, "sql", .{ .string = "SELECT id, name FROM products" });
    try std.testing.expectError(error.TenantFilterRequired, registry.dispatch("db.query", &ctx, .{ .object = bad }));
}
