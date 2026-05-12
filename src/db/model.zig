const std = @import("std");
const DB = @import("db.zig").DB;
const ResultSet = @import("result.zig").ResultSet;
const SqlParam = @import("sql_param.zig").SqlParam;

/// Active Record base for models with parameterized queries (SQL injection safe)
/// Usage: const UserModel = Model(User, "users");
pub fn Model(comptime T: type, comptime table_name: []const u8) type {
    return struct {
        const Self = @This();

        /// Model instance with optional ID
        pub const Instance = struct {
            id: ?i64 = null,
            data: T,

            pub fn deinit(self: *const Instance, allocator: std.mem.Allocator) void {
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (field.type == []const u8) {
                        const val = @field(self.data, field.name);
                        if (val.len > 0) {
                            allocator.free(val);
                        }
                    }
                }
            }

            /// Save (insert or update) this instance
            pub fn save(self: *Instance, db: *DB) !void {
                if (self.id) |id_val| {
                    try self.update(db, id_val);
                } else {
                    try self.insert(db);
                }
            }

            /// Insert new record using parameter binding
            fn insert(self: *Instance, db: *DB) !void {
                const sql = try std.fmt.allocPrintSentinel(db.allocator,
                    "INSERT INTO {s} (name, email, age) VALUES (?, ?, ?)", .{table_name}, 0);
                defer db.allocator.free(sql);

                const params = &.{
                    SqlParam{ .text = self.data.name },
                    SqlParam{ .text = self.data.email },
                    SqlParam{ .int = self.data.age },
                };

                try db.execParams(sql, params);
                self.id = db.lastInsertId() catch null;
            }

            /// Update existing record using parameter binding
            fn update(self: *Instance, db: *DB, id: i64) !void {
                const sql = try std.fmt.allocPrintSentinel(db.allocator,
                    "UPDATE {s} SET name = ?, email = ?, age = ? WHERE id = ?", .{table_name}, 0);
                defer db.allocator.free(sql);

                const params = &.{
                    SqlParam{ .text = self.data.name },
                    SqlParam{ .text = self.data.email },
                    SqlParam{ .int = self.data.age },
                    SqlParam{ .int = id },
                };

                try db.execParams(sql, params);
            }

            /// Delete this record
            pub fn delete(self: *Instance, db: *DB) !void {
                if (self.id) |id_val| {
                    try Self.deleteById(db, id_val);
                    self.id = null;
                }
            }
        };

        /// Find record by ID (parameterized)
        pub fn findById(db: *DB, id: i64, allocator: std.mem.Allocator) !?Instance {
            const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT * FROM {s} WHERE id = ?", .{table_name}, 0);
            defer allocator.free(sql);

            const params = &[_]SqlParam{.{ .int = id }};
            var result = try db.queryParams(sql, params);
            defer result.deinit();

            if (result.next()) {
                if (result.getCurrentRowMap()) |row| {
                    return try Self.mapFromRow(allocator, row);
                }
            }
            return null;
        }

        /// Find all records
        pub fn findAll(db: *DB, allocator: std.mem.Allocator) ![]Instance {
            const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT * FROM {s}", .{table_name}, 0);
            defer allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            var list = std.ArrayList(Instance).empty;
            errdefer {
                for (list.items) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(list.toOwnedSlice(allocator) catch &[_]Instance{});
            }

            while (result.next()) {
                if (result.getCurrentRowMap()) |row| {
                    const instance = try Self.mapFromRow(allocator, row);
                    try list.append(allocator, instance);
                }
            }

            return list.toOwnedSlice(allocator);
        }

        /// Find records with parameterized WHERE clause
        /// where_sql: e.g. "age > ? AND name = ?"
        /// params: bound values for the placeholders
        pub fn findWhere(db: *DB, where_sql: [:0]const u8, params: []const SqlParam, allocator: std.mem.Allocator) ![]Instance {
            const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT * FROM {s} WHERE {s}", .{ table_name, where_sql }, 0);
            defer allocator.free(sql);

            var result = try db.queryParams(sql, params);
            defer result.deinit();

            var list = std.ArrayList(Instance).empty;
            errdefer {
                for (list.items) |*item| {
                    item.data.name = "";
                    item.data.email = "";
                }
                list.deinit();
            }

            while (result.next()) {
                if (result.getCurrentRowMap()) |row| {
                    const instance = try Self.mapFromRow(allocator, row);
                    try list.append(allocator, instance);
                }
            }

            return list.toOwnedSlice();
        }

        /// Delete record by ID (parameterized)
        pub fn deleteById(db: *DB, id: i64) !void {
            const sql = try std.fmt.allocPrintSentinel(db.allocator, "DELETE FROM {s} WHERE id = ?", .{table_name}, 0);
            defer db.allocator.free(sql);
            const params = &[_]SqlParam{.{ .int = id }};
            try db.execParams(sql, params);
        }

        /// Count all records
        pub fn count(db: *DB) !i64 {
            const sql = try std.fmt.allocPrintSentinel(db.allocator, "SELECT COUNT(*) FROM {s}", .{table_name}, 0);
            defer db.allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            if (result.next()) {
                if (try result.getInt(0)) |c| {
                    return c;
                }
            }
            return 0;
        }

        /// Map a ResultSet row to a model Instance
        fn mapFromRow(allocator: std.mem.Allocator, row: ResultSet.RowMap) !Instance {
            // Map columns by name; assumes T has name, email, age fields
            const id_text = row.get("id");
            const id: ?i64 = if (id_text) |t| std.fmt.parseInt(i64, t, 10) catch null else null;

            const name_val = row.get("name") orelse "";
            const email_val = row.get("email") orelse "";

            return Instance{
                .id = id,
                .data = T{
                    .name = if (name_val.len > 0) try allocator.dupe(u8, name_val) else "",
                    .email = if (email_val.len > 0) try allocator.dupe(u8, email_val) else "",
                    .age = if (row.get("age")) |a| std.fmt.parseInt(i32, a, 10) catch 0 else 0,
                },
            };
        }
    };
}

/// Example User model
pub const User = struct {
    name: []const u8,
    email: []const u8,
    age: i32,
};

/// User model type
pub const UserModel = Model(User, "users");

test "model basic" {
    const allocator = std.testing.allocator;

    const DBConfig = @import("config.zig").DBConfig;
    const config = DBConfig.sqliteMemory();

    var db = try DB.init(allocator, config);
    defer db.deinit();

    try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT, age INTEGER)");

    var user = UserModel.Instance{
        .data = User{
            .name = "Alice",
            .email = "alice@example.com",
            .age = 25,
        },
    };

    try user.save(&db);
    try std.testing.expect(user.id != null);

    // Test findById
    const found = try UserModel.findById(&db, user.id.?, allocator);
    defer {
        if (found) |*f| {
            f.deinit(allocator);
        }
    }
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Alice", found.?.data.name);

    // Test findAll
    const all = try UserModel.findAll(&db, allocator);
    defer {
        for (all) |*item| {
            item.deinit(allocator);
        }
        allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 1), all.len);

    // Test count
    const cnt = try UserModel.count(&db);
    try std.testing.expectEqual(@as(i64, 1), cnt);

    // Test delete
    try UserModel.deleteById(&db, user.id.?);
    const after_delete = try UserModel.findById(&db, user.id.?, allocator);
    defer {
        if (after_delete) |*f| {
            f.deinit(allocator);
        }
    }
    try std.testing.expect(after_delete == null);
}
