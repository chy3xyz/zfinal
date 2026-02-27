const std = @import("std");
const zfinal = @import("zfinal");

/// Collection represents a database table/collection
pub const Collection = struct {
    name: []const u8,

    /// List all collections (tables)
    pub fn listAll(db: *zfinal.DB, allocator: std.mem.Allocator) ![][]const u8 {
        const sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE '\\_%' ESCAPE '\\' ORDER BY name";
        var rs = try db.query(sql);
        defer rs.deinit();

        var collections = std.ArrayList([]const u8).init(allocator);
        defer collections.deinit();

        while (rs.next()) {
            const row = rs.getCurrentRowMap().?;
            if (row.get("name")) |name| {
                try collections.append(try allocator.dupe(u8, name));
            }
        }

        return try collections.toOwnedSlice();
    }

    /// Check if collection exists
    pub fn exists(name: []const u8, db: *zfinal.DB, allocator: std.mem.Allocator) !bool {
        const sql = try std.fmt.allocPrintZ(
            allocator,
            "SELECT COUNT(*) as count FROM sqlite_master WHERE type='table' AND name = '{s}'",
            .{name},
        );
        defer allocator.free(sql);

        var rs = try db.query(sql);
        defer rs.deinit();

        if (rs.next()) {
            const row = rs.getCurrentRowMap().?;
            if (row.get("count")) |count_str| {
                const count = try std.fmt.parseInt(i64, count_str, 10);
                return count > 0;
            }
        }

        return false;
    }

    /// Create a new collection (table)
    pub fn create(name: []const u8, schema: []const u8, db: *zfinal.DB, allocator: std.mem.Allocator) !void {
        var sql_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&sql_buf);
        const writer = fbs.writer();

        try writer.print("CREATE TABLE {s} (id INTEGER PRIMARY KEY AUTOINCREMENT, ", .{name});
        if (schema.len > 0) {
            try writer.print("{s}, ", .{schema});
        }
        try writer.writeAll("created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)");

        const sql = try std.fmt.allocPrintZ(allocator, "{s}", .{fbs.getWritten()});
        defer allocator.free(sql);

        try db.exec(sql);
    }

    /// Drop collection (table)
    pub fn drop(name: []const u8, db: *zfinal.DB, allocator: std.mem.Allocator) !void {
        const sql = try std.fmt.allocPrintZ(allocator, "DROP TABLE IF EXISTS {s}", .{name});
        defer allocator.free(sql);

        try db.exec(sql);
    }
};
