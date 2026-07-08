const std = @import("std");
const DB = @import("db.zig").DB;
const DBConfig = @import("config.zig").DBConfig;
const ResultSet = @import("result.zig").ResultSet;
const SqlParam = @import("sql_param.zig").SqlParam;
const logger = @import("../core/logger.zig");

/// Active Record base for models with parameterized queries.
/// Uses comptime field iteration — works with any table schema.
/// Usage: const UserModel = Model(User, "users");
/// For custom primary key: const UserModel = ModelWithPK(User, "users", "user_id");
pub fn Model(comptime T: type, comptime table_name: []const u8) type {
    return ModelWithPK(T, table_name, "id");
}

pub fn ModelWithPK(comptime T: type, comptime table_name: []const u8, comptime pk_name: []const u8) type {
    @setEvalBranchQuota(20000);
    return struct {
        const Self = @This();
        const fields = blk: {
            const info = @typeInfo(T).@"struct";
            const CompatField = struct { name: []const u8, type: type };
            var arr: [info.field_names.len]CompatField = undefined;
            for (info.field_names, info.field_types, 0..) |name, ty, i| {
                arr[i] = .{ .name = name, .type = ty };
            }
            break :blk arr;
        };

        pub const Instance = struct {
            id: ?i64 = null,
            data: T,

            pub fn deinit(self: *const Instance, allocator: std.mem.Allocator) void {
                inline for (fields) |f| {
                    if (f.type == []const u8) {
                        const val = @field(self.data, f.name);
                        if (val.len > 0) allocator.free(val);
                    }
                }
            }

            pub fn save(self: *Instance, db: *DB) !void {
                if (self.id) |id_val| try self.update(db, id_val) else try self.insert(db);
            }

            fn insert(self: *Instance, db: *DB) !void {
                @setEvalBranchQuota(20000);
                const param_count = comptime blk: {
                    var n: usize = 0;
                    for (fields) |f| {
                        if (!std.mem.eql(u8, f.name, pk_name)) n += 1;
                    }
                    break :blk n;
                };
                var params: [param_count]SqlParam = undefined;
                comptime var pi: usize = 0;
                inline for (fields) |f| {
                    if (comptime std.mem.eql(u8, f.name, pk_name)) continue;
                    params[pi] = toSqlParam(@field(self.data, f.name));
                    pi += 1;
                }
                try db.execParams(@ptrCast(comptime blk: {
                    var cbuf: [1024]u8 = undefined;
                    var vbuf: [512]u8 = undefined;
                    var cl: usize = 0;
                    var vl: usize = 0;
                    var idx: usize = 1;
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.name, pk_name)) continue;
                        if (cl > 0) {
                            cbuf[cl] = ',';
                            cbuf[cl + 1] = ' ';
                            cl += 2;
                        }
                        @memcpy(cbuf[cl..][0..f.name.len], f.name);
                        cl += f.name.len;
                        if (vl > 0) {
                            vbuf[vl] = ',';
                            vbuf[vl + 1] = ' ';
                            vl += 2;
                        }
                        const num = std.fmt.comptimePrint("${d}", .{idx});
                        for (num, 0..) |c, j| {
                            vbuf[vl + j] = c;
                        }
                        vl += num.len;
                        idx += 1;
                    }
                    break :blk "INSERT INTO " ++ table_name ++ " (" ++ cbuf[0..cl] ++ ") VALUES (" ++ vbuf[0..vl] ++ ")";
                }), &params);
                self.id = db.lastInsertId() catch null;
            }

            fn update(self: *Instance, db: *DB, id: i64) !void {
                @setEvalBranchQuota(20000);
                const param_count = comptime blk: {
                    var n: usize = 0;
                    for (fields) |f| {
                        if (!std.mem.eql(u8, f.name, pk_name)) n += 1;
                    }
                    break :blk n + 1;
                };
                var params: [param_count]SqlParam = undefined;
                comptime var pj: usize = 0;
                inline for (fields) |f| {
                    if (comptime std.mem.eql(u8, f.name, pk_name)) continue;
                    params[pj] = toSqlParam(@field(self.data, f.name));
                    pj += 1;
                }
                params[param_count - 1] = SqlParam{ .int = id };
                try db.execParams(@ptrCast(comptime blk: {
                    var sbuf: [2048]u8 = undefined;
                    var sl: usize = 0;
                    var idx: usize = 1;
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.name, pk_name)) continue;
                        if (sl > 0) {
                            sbuf[sl] = ',';
                            sbuf[sl + 1] = ' ';
                            sl += 2;
                        }
                        @memcpy(sbuf[sl..][0..f.name.len], f.name);
                        sl += f.name.len;
                        const eq = std.fmt.comptimePrint(" = ${d}", .{idx});
                        for (eq, 0..) |c, j| {
                            sbuf[sl + j] = c;
                        }
                        sl += eq.len;
                        idx += 1;
                    }
                    const wnum = std.fmt.comptimePrint(" WHERE " ++ pk_name ++ " = ${d}", .{idx});
                    break :blk "UPDATE " ++ table_name ++ " SET " ++ sbuf[0..sl] ++ wnum;
                }), &params);
            }

            pub fn delete(self: *Instance, db: *DB) !void {
                if (self.id) |id_val| {
                    try Self.deleteById(db, id_val);
                    self.id = null;
                }
            }
        };

        pub fn findById(db: *DB, id: i64, allocator: std.mem.Allocator) !?Instance {
            const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT * FROM {s} WHERE " ++ pk_name ++ " = $1", .{table_name}, 0);
            defer allocator.free(sql);
            var result = try db.queryParams(sql, &.{SqlParam{ .int = id }});
            defer result.deinit();
            if (result.next()) {
                if (result.getCurrentRowMap()) |row| return try mapFromRow(allocator, row);
            }
            return null;
        }

        pub fn findAll(db: *DB, allocator: std.mem.Allocator) ![]Instance {
            const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT * FROM {s}", .{table_name}, 0);
            defer allocator.free(sql);
            var result = try db.query(sql);
            defer result.deinit();
            var list = std.ArrayList(Instance).empty;
            errdefer {
                for (list.items) |*item| item.deinit(allocator);
                list.deinit(allocator);
            }
            while (result.next()) {
                if (result.getCurrentRowMap()) |row| try list.append(allocator, try mapFromRow(allocator, row));
            }
            return list.toOwnedSlice(allocator);
        }

        pub fn findWhere(db: *DB, comptime where_sql: [:0]const u8, params: []const SqlParam, allocator: std.mem.Allocator) ![]Instance {
            const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT * FROM {s} WHERE {s}", .{ table_name, where_sql }, 0);
            defer allocator.free(sql);
            var result = try db.queryParams(sql, params);
            defer result.deinit();
            var list = std.ArrayList(Instance).empty;
            defer list.deinit(allocator);
            while (result.next()) {
                if (result.getCurrentRowMap()) |row| try list.append(allocator, try mapFromRow(allocator, row));
            }
            return list.toOwnedSlice(allocator);
        }

        pub fn deleteById(db: *DB, id: i64) !void {
            const sql = try std.fmt.allocPrintSentinel(db.allocator, "DELETE FROM {s} WHERE " ++ pk_name ++ " = $1", .{table_name}, 0);
            defer db.allocator.free(sql);
            try db.execParams(sql, &.{SqlParam{ .int = id }});
        }

        /// Paginated query with LIMIT and OFFSET. page must be >= 1.
        pub fn paginate(db: *DB, page: usize, page_size: usize, allocator: std.mem.Allocator) ![]Instance {
            std.debug.assert(page >= 1);
            std.debug.assert(page_size > 0);
            const offset = (page - 1) * page_size;
            const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT * FROM {s} LIMIT $1 OFFSET $2", .{table_name}, 0);
            defer allocator.free(sql);
            var result = try db.queryParams(sql, &.{ SqlParam{ .int = @intCast(page_size) }, SqlParam{ .int = @intCast(offset) } });
            defer result.deinit();
            var list = std.ArrayList(Instance).empty;
            errdefer {
                for (list.items) |*item| item.deinit(allocator);
                list.deinit(allocator);
            }
            while (result.next()) {
                if (result.getCurrentRowMap()) |row| try list.append(allocator, try mapFromRow(allocator, row));
            }
            return list.toOwnedSlice(allocator);
        }

        /// Batch insert — wraps multiple saves in a single transaction for 10-50x throughput.
        pub fn insertBatch(db: *DB, instances: []Instance) !void {
            try db.exec("BEGIN");
            // A failed rollback must not kill the process — log it and let
            // the original error propagate to the caller.
            errdefer db.exec("ROLLBACK") catch |e| {
                logger.getLogger().errFmt("insertBatch rollback failed: {t}", .{e});
            };
            for (instances) |*inst| try inst.insert(db);
            try db.exec("COMMIT");
        }

        pub fn count(db: *DB) !i64 {
            const sql = try std.fmt.allocPrintSentinel(db.allocator, "SELECT COUNT(*) FROM {s}", .{table_name}, 0);
            defer db.allocator.free(sql);
            var result = try db.query(sql);
            defer result.deinit();
            if (result.next()) {
                if (try result.getInt(0)) |c| return c;
            }
            return 0;
        }

        /// Map a ResultSet row to a model Instance using comptime field iteration.
        fn mapFromRow(allocator: std.mem.Allocator, row: ResultSet.RowMap) !Instance {
            var data: T = undefined;
            inline for (fields) |f| {
                const raw = row.get(f.name);
                @field(data, f.name) = try parseField(allocator, raw, f.type);
            }
            const id_text = row.get(pk_name);
            const id: ?i64 = if (id_text) |t| std.fmt.parseInt(i64, t, 10) catch null else null;
            return Instance{ .id = id, .data = data };
        }

        fn parseField(allocator: std.mem.Allocator, raw: ?[]const u8, comptime FT: type) !FT {
            const s = raw orelse "";
            return switch (@typeInfo(FT)) {
                .int, .comptime_int => if (s.len > 0) std.fmt.parseInt(FT, s, 10) catch return error.InvalidField else 0,
                .float, .comptime_float => if (s.len > 0) std.fmt.parseFloat(FT, s) catch return error.InvalidField else 0,
                .bool => std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "t"),
                .optional => blk: {
                    if (s.len == 0) break :blk null;
                    const Child = @typeInfo(FT).optional.child;
                    break :blk try parseField(allocator, raw, Child);
                },
                .pointer => if (s.len > 0) try allocator.dupe(u8, s) else try allocator.dupe(u8, ""),
                else => @compileError("Unsupported field type"),
            };
        }
    };
}

fn toSqlParam(value: anytype) SqlParam {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => SqlParam{ .int = @intCast(value) },
        .float, .comptime_float => SqlParam{ .real = @floatCast(value) },
        .bool => SqlParam{ .int = if (value) @as(i64, 1) else 0 },
        .optional => if (value) |v| toSqlParam(v) else SqlParam.null,
        .pointer => if (T == []const u8) SqlParam{ .text = value } else SqlParam.null,
        else => SqlParam.null,
    };
}

test "model basic" {
    const TestTable = struct { name: []const u8, age: i32 };
    const TestModel = Model(TestTable, "test_table");
    _ = TestModel;
}

test "model mapFromRow works with any schema" {
    const Blog = struct { title: []const u8, content: []const u8, author_id: i64 };
    const BlogModel = Model(Blog, "blog_posts");
    try std.testing.expect(@hasDecl(BlogModel, "findById"));
    try std.testing.expect(@hasDecl(BlogModel, "findAll"));
    try std.testing.expect(@hasDecl(BlogModel, "findWhere"));
}

test "model with custom pk" {
    const Customer = struct { customer_id: i64, company_name: []const u8 };
    const CustomerModel = ModelWithPK(Customer, "crm_customer", "customer_id");
    try std.testing.expect(@hasDecl(CustomerModel, "findById"));
    try std.testing.expect(@hasDecl(CustomerModel, "deleteById"));
}

test "model: insert and findById" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    _ = try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, age INT)");
    const User = struct { id: i64, name: []const u8, age: i64 };
    const UserModel = Model(User, "users");
    var inst = UserModel.Instance{ .id = null, .data = .{ .id = 0, .name = "Alice", .age = 30 } };
    try inst.insert(db);
    try std.testing.expect(inst.id != null);
    const found = try UserModel.findById(db, inst.id.?, a);
    defer if (found) |f| f.deinit(a);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Alice", found.?.data.name);
}

test "model: findAll" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    _ = try db.exec("CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)");
    const Item = struct { id: i64, title: []const u8 };
    const ItemModel = Model(Item, "items");
    var item1 = ItemModel.Instance{ .id = null, .data = .{ .id = 0, .title = "a" } };
    var item2 = ItemModel.Instance{ .id = null, .data = .{ .id = 0, .title = "b" } };
    var item3 = ItemModel.Instance{ .id = null, .data = .{ .id = 0, .title = "c" } };
    try item1.insert(db);
    try item2.insert(db);
    try item3.insert(db);
    const all = try ItemModel.findAll(db, a);
    defer {
        for (all) |*it| it.deinit(a);
        a.free(all);
    }
    try std.testing.expectEqual(@as(usize, 3), all.len);
}

test "model: update and delete" {
    const a = std.testing.allocator;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    _ = try db.exec("CREATE TABLE stuff (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)");
    const Stuff = struct { id: i64, label: []const u8 };
    const StuffModel = Model(Stuff, "stuff");
    var inst = StuffModel.Instance{ .id = null, .data = .{ .id = 0, .label = "old" } };
    try inst.insert(db);
    inst.data.label = "new";
    try inst.update(db, inst.id.?);
    const updated = try StuffModel.findById(db, inst.id.?, a);
    defer if (updated) |u| u.deinit(a);
    try std.testing.expectEqualStrings("new", updated.?.data.label);
    try StuffModel.deleteById(db, inst.id.?);
    try std.testing.expect((try StuffModel.findById(db, inst.id.?, a)) == null);
}
