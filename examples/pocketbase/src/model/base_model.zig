const std = @import("std");
const zfinal = @import("zfinal");

/// Schema information for a collection
pub const Schema = struct {
    columns: []ColumnInfo,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Schema) void {
        for (self.columns) |*col| {
            self.allocator.free(col.name);
            self.allocator.free(col.type_name);
        }
        self.allocator.free(self.columns);
    }
};

pub const ColumnInfo = struct {
    name: []const u8,
    type_name: []const u8,
    nullable: bool = true,
};

/// Base model providing common CRUD operations
pub const BaseModel = struct {
    table_name: []const u8,
    db: *zfinal.DB,
    allocator: std.mem.Allocator,

    pub fn init(table_name: []const u8, db: *zfinal.DB, allocator: std.mem.Allocator) BaseModel {
        return .{
            .table_name = table_name,
            .db = db,
            .allocator = allocator,
        };
    }

    /// Get schema for this table
    pub fn getSchema(self: *const BaseModel) !Schema {
        const sql = try std.fmt.allocPrintZ(self.allocator, "PRAGMA table_info({s})", .{self.table_name});
        defer self.allocator.free(sql);

        var rs = try self.db.query(sql);
        defer rs.deinit();

        var columns = std.ArrayList(ColumnInfo).init(self.allocator);
        defer columns.deinit();

        while (rs.next()) {
            const row = rs.getCurrentRowMap().?;
            const name = try self.allocator.dupe(u8, row.get("name").?);
            const type_name = try self.allocator.dupe(u8, row.get("type").?);
            const notnull = row.get("notnull");

            try columns.append(.{
                .name = name,
                .type_name = type_name,
                .nullable = if (notnull) |nn| !std.mem.eql(u8, nn, "1") else true,
            });
        }

        return Schema{
            .columns = try columns.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    /// Find record by ID
    pub fn findById(self: *const BaseModel, id: []const u8) !?zfinal.ResultSet {
        const query = try std.fmt.allocPrintZ(
            self.allocator,
            "SELECT * FROM {s} WHERE id = '{s}' LIMIT 1",
            .{ self.table_name, id },
        );
        defer self.allocator.free(query);

        return try self.db.query(query);
    }

    /// Find all records with limit
    pub fn findAll(self: *const BaseModel, limit: usize) !zfinal.ResultSet {
        const sql = try std.fmt.allocPrintZ(
            self.allocator,
            "SELECT * FROM {s} ORDER BY created_at DESC LIMIT {d}",
            .{ self.table_name, limit },
        );
        defer self.allocator.free(sql);

        return try self.db.query(sql);
    }

    /// Delete record by ID
    pub fn deleteById(self: *const BaseModel, id: []const u8) !void {
        const sql = try std.fmt.allocPrintZ(
            self.allocator,
            "DELETE FROM {s} WHERE id = '{s}'",
            .{ self.table_name, id },
        );
        defer self.allocator.free(sql);

        try self.db.exec(sql);
    }

    /// Count total records
    pub fn count(self: *const BaseModel) !i64 {
        const sql = try std.fmt.allocPrintZ(
            self.allocator,
            "SELECT COUNT(*) as count FROM {s}",
            .{self.table_name},
        );
        defer self.allocator.free(sql);

        var rs = try self.db.query(sql);
        defer rs.deinit();

        if (rs.next()) {
            const row = rs.getCurrentRowMap().?;
            if (row.get("count")) |count_str| {
                return try std.fmt.parseInt(i64, count_str, 10);
            }
        }

        return 0;
    }
};
