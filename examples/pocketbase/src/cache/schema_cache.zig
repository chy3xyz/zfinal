const std = @import("std");
const zfinal = @import("zfinal");
const CacheKit = zfinal.CacheKit;

/// Schema cache to avoid repeated PRAGMA queries
pub const SchemaCache = struct {
    cache: CacheKit,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SchemaCache {
        return .{
            .cache = CacheKit.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SchemaCache) void {
        self.cache.deinit();
    }

    /// Get schema from cache or fetch from DB
    pub fn getSchema(self: *SchemaCache, table: []const u8, db: *zfinal.DB) ![]const u8 {
        const cache_key = try std.fmt.allocPrint(self.allocator, "schema:{s}", .{table});
        defer self.allocator.free(cache_key);

        // Try cache first
        if (self.cache.get(cache_key)) |cached| {
            return cached;
        }

        // Fetch from DB
        const sql = try std.fmt.allocPrintZ(self.allocator, "PRAGMA table_info({s})", .{table});
        defer self.allocator.free(sql);

        var rs = try db.query(sql);
        defer rs.deinit();

        // Build schema JSON
        var schema_json = std.ArrayList(u8).init(self.allocator);
        defer schema_json.deinit();

        try schema_json.writer().writeAll("[");
        var first = true;

        while (rs.next()) {
            if (!first) try schema_json.writer().writeAll(",");
            first = false;

            const row = rs.getCurrentRowMap().?;
            try schema_json.writer().writeAll("{");
            try schema_json.writer().print("\"name\":\"{s}\",", .{row.get("name").?});
            try schema_json.writer().print("\"type\":\"{s}\"", .{row.get("type").?});
            try schema_json.writer().writeAll("}");
        }

        try schema_json.writer().writeAll("]");

        const schema_str = try schema_json.toOwnedSlice();

        // Cache for 5 minutes
        try self.cache.set(cache_key, schema_str, 300);

        return schema_str;
    }

    /// Invalidate schema cache for a table
    pub fn invalidate(self: *SchemaCache, table: []const u8) !void {
        const cache_key = try std.fmt.allocPrint(self.allocator, "schema:{s}", .{table});
        defer self.allocator.free(cache_key);

        try self.cache.delete(cache_key);
    }

    /// Clear all cached schemas
    pub fn clear(self: *SchemaCache) void {
        self.cache.clear();
    }
};
