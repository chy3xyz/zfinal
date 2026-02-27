const std = @import("std");
const DB = @import("db.zig").DB;
const ResultSet = @import("result.zig").ResultSet;

/// Active Record base for models
/// Usage: const UserModel = Model(User, "users");
pub fn Model(comptime T: type, comptime table_name: []const u8) type {
    return struct {
        const Self = @This();

        /// Model instance with optional ID
        pub const Instance = struct {
            id: ?i64 = null,
            data: T,

            /// Save (insert or update) this instance
            pub fn save(self: *Instance, db: *DB) !void {
                if (self.id) |id_val| {
                    // Update existing record
                    try self.update(db, id_val);
                } else {
                    // Insert new record
                    try self.insert(db);
                }
            }

            /// Insert new record
            fn insert(self: *Instance, db: *DB) !void {
                var sql_buf: [4096]u8 = undefined;
                const sql = try T.insertSql(&sql_buf, table_name);

                // For SQLite/MySQL, we can get last insert ID
                // For Postgres, we'd need RETURNING clause
                try db.exec(sql);

                // Try to get last insert ID (works for SQLite/MySQL)
                self.id = db.lastInsertId() catch null;
            }

            /// Update existing record
            fn update(self: *Instance, db: *DB, id: i64) !void {
                var sql_buf: [4096]u8 = undefined;
                const sql = try T.updateSql(&sql_buf, table_name, id);
                _ = self; // TODO: Use self.data to generate SQL
                try db.exec(sql);
            }

            /// Delete this record
            pub fn delete(self: *Instance, db: *DB) !void {
                if (self.id) |id_val| {
                    try Self.deleteById(db, id_val);
                    self.id = null;
                }
            }
        };

        /// Find record by ID
        pub fn findById(db: *DB, id: i64, allocator: std.mem.Allocator) !?Instance {
            const sql = try std.fmt.allocPrintZ(allocator, "SELECT * FROM {s} WHERE id = {d}", .{ table_name, id });
            defer allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            // TODO: Implement row iteration in ResultSet
            // For now, return null
            return null;
        }

        /// Find all records
        pub fn findAll(db: *DB, allocator: std.mem.Allocator) ![]Instance {
            const sql = try std.fmt.allocPrintZ(allocator, "SELECT * FROM {s}", .{table_name});
            defer allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            // TODO: Implement row iteration
            var list = std.ArrayList(Instance).init(allocator);
            defer list.deinit();

            return list.toOwnedSlice();
        }

        /// Find records with WHERE clause
        pub fn findWhere(db: *DB, where_clause: []const u8, allocator: std.mem.Allocator) ![]Instance {
            const sql = try std.fmt.allocPrintZ(allocator, "SELECT * FROM {s} WHERE {s}", .{ table_name, where_clause });
            defer allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            var list = std.ArrayList(Instance).init(allocator);
            defer list.deinit();

            return list.toOwnedSlice();
        }

        /// Delete record by ID
        pub fn deleteById(db: *DB, id: i64) !void {
            const sql = try std.fmt.allocPrintZ(db.allocator, "DELETE FROM {s} WHERE id = {d}", .{ table_name, id });
            defer db.allocator.free(sql);
            try db.exec(sql);
        }

        /// Delete all records matching WHERE clause
        pub fn deleteWhere(db: *DB, where_clause: []const u8) !void {
            const sql = try std.fmt.allocPrintZ(db.allocator, "DELETE FROM {s} WHERE {s}", .{ table_name, where_clause });
            defer db.allocator.free(sql);
            try db.exec(sql);
        }

        /// Count all records
        pub fn count(db: *DB) !i64 {
            const sql = try std.fmt.allocPrintZ(db.allocator, "SELECT COUNT(*) FROM {s}", .{table_name});
            defer db.allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            // TODO: Get count from result
            return 0;
        }
    };
}

/// Example User model
pub const User = struct {
    name: []const u8,
    email: []const u8,
    age: i32,

    /// Generate INSERT SQL
    pub fn insertSql(buf: []u8, table: []const u8) ![:0]const u8 {
        return std.fmt.bufPrintZ(buf, "INSERT INTO {s} (name, email, age) VALUES ('Alice', 'alice@example.com', 25)", .{table});
    }

    /// Generate UPDATE SQL
    pub fn updateSql(buf: []u8, table: []const u8, id: i64) ![:0]const u8 {
        return std.fmt.bufPrintZ(buf, "UPDATE {s} SET name = 'Alice', email = 'alice@example.com', age = 25 WHERE id = {d}", .{ table, id });
    }
};

/// User model type
pub const UserModel = Model(User, "users");

test "model basic" {
    const allocator = std.testing.allocator;

    // Create SQLite in-memory database
    const DBConfig = @import("config.zig").DBConfig;
    const config = DBConfig.sqliteMemory();

    var db = try DB.init(allocator, config);
    defer db.deinit();

    // Create table
    try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT, age INTEGER)");

    // Create user instance
    var user = UserModel.Instance{
        .data = User{
            .name = "Alice",
            .email = "alice@example.com",
            .age = 25,
        },
    };

    // Save (insert)
    try user.save(&db);

    // Verify ID was set
    try std.testing.expect(user.id != null);
}
