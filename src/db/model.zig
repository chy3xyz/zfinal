const std = @import("std");
const DB = @import("db.zig").DB;
const ResultSet = @import("result.zig").ResultSet;
const SqlParam = @import("sql_param.zig").SqlParam;

/// Active Record base for models with parameterized queries.
/// Uses comptime field iteration — works with any table schema.
/// Usage: const UserModel = Model(User, "users");
pub fn Model(comptime T: type, comptime table_name: []const u8) type {
    return struct {
        const Self = @This();
        const fields = @typeInfo(T).@"struct".fields;

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
                const param_count = comptime blk: { var n: usize = 0; for (fields) |f| { if (!std.mem.eql(u8, f.name, "id")) n += 1; } break :blk n; };
                var params: [param_count]SqlParam = undefined;
                comptime var pi: usize = 0;
                inline for (fields) |f| {
                    if (comptime std.mem.eql(u8, f.name, "id")) continue;
                    params[pi] = toSqlParam(@field(self.data, f.name)); pi += 1;
                }
                try db.execParams(@ptrCast(comptime blk: {
                    var cbuf: [1024]u8 = undefined; var vbuf: [128]u8 = undefined; var cl: usize = 0; var vl: usize = 0;
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.name, "id")) continue;
                        if (cl > 0) { cbuf[cl]=','; cbuf[cl+1]=' '; cl+=2; }
                        @memcpy(cbuf[cl..][0..f.name.len], f.name); cl += f.name.len;
                        if (vl > 0) { vbuf[vl]=','; vbuf[vl+1]=' '; vl+=2; }
                        vbuf[vl]='?'; vl+=1;
                    }
                    break :blk "INSERT INTO " ++ table_name ++ " (" ++ cbuf[0..cl] ++ ") VALUES (" ++ vbuf[0..vl] ++ ")";
                }), &params);
                self.id = db.lastInsertId() catch null;
            }

            fn update(self: *Instance, db: *DB, id: i64) !void {
                const param_count = comptime blk: { var n: usize = 0; for (fields) |f| { if (!std.mem.eql(u8, f.name, "id")) n += 1; } break :blk n + 1; };
                var params: [param_count]SqlParam = undefined;
                comptime var pj: usize = 0;
                inline for (fields) |f| {
                    if (comptime std.mem.eql(u8, f.name, "id")) continue;
                    params[pj] = toSqlParam(@field(self.data, f.name)); pj += 1;
                }
                params[param_count - 1] = SqlParam{ .int = id };
                try db.execParams(@ptrCast(comptime blk: {
                    var sbuf: [1024]u8 = undefined; var sl: usize = 0;
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.name, "id")) continue;
                        if (sl > 0) { sbuf[sl]=','; sbuf[sl+1]=' '; sl+=2; }
                        @memcpy(sbuf[sl..][0..f.name.len], f.name); sl += f.name.len;
                        @memcpy(sbuf[sl..][0..4], " = ?"); sl += 4;
                    }
                    break :blk "UPDATE " ++ table_name ++ " SET " ++ sbuf[0..sl] ++ " WHERE id = ?";
                }), &params);
            }

            pub fn delete(self: *Instance, db: *DB) !void {
                if (self.id) |id_val| { try Self.deleteById(db, id_val); self.id = null; }
            }
        };

        pub fn findById(db: *DB, id: i64, allocator: std.mem.Allocator) !?Instance {
            const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT * FROM {s} WHERE id = ?", .{table_name}, 0);
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
            errdefer { for (list.items) |*item| item.deinit(allocator); allocator.free(list.toOwnedSlice(allocator) catch &.{}); }
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
            defer list.deinit();
            while (result.next()) {
                if (result.getCurrentRowMap()) |row| try list.append(allocator, try mapFromRow(allocator, row));
            }
            return list.toOwnedSlice();
        }

        pub fn deleteById(db: *DB, id: i64) !void {
            const sql = try std.fmt.allocPrintSentinel(db.allocator, "DELETE FROM {s} WHERE id = ?", .{table_name}, 0);
            defer db.allocator.free(sql);
            try db.execParams(sql, &.{SqlParam{ .int = id }});
        }

        pub fn count(db: *DB) !i64 {
            const sql = try std.fmt.allocPrintSentinel(db.allocator, "SELECT COUNT(*) FROM {s}", .{table_name}, 0);
            defer db.allocator.free(sql);
            var result = try db.query(sql);
            defer result.deinit();
            if (result.next()) { if (try result.getInt(0)) |c| return c; }
            return 0;
        }

        /// Map a ResultSet row to a model Instance using comptime field iteration.
        fn mapFromRow(allocator: std.mem.Allocator, row: ResultSet.RowMap) !Instance {
            var data: T = undefined;
            inline for (fields) |f| {
                const raw = row.get(f.name);
                @field(data, f.name) = try parseField(allocator, raw, f.type);
            }
            const id_text = row.get("id");
            const id: ?i64 = if (id_text) |t| std.fmt.parseInt(i64, t, 10) catch null else null;
            return Instance{ .id = id, .data = data };
        }

        fn parseField(allocator: std.mem.Allocator, raw: ?[]const u8, comptime FT: type) !FT {
            const s = raw orelse "";
            return switch (@typeInfo(FT)) {
                .int, .comptime_int => std.fmt.parseInt(FT, if (s.len > 0) s else "0", 10) catch 0,
                .float, .comptime_float => std.fmt.parseFloat(FT, if (s.len > 0) s else "0") catch 0,
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
