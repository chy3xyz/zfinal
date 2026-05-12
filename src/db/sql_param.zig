const std = @import("std");

/// SQL parameter value for prepared statements
pub const SqlParam = union(enum) {
    int: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
    null,

    pub fn format(self: SqlParam, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .int => |v| try writer.print("{d}", .{v}),
            .real => |v| try writer.print("{d}", .{v}),
            .text => |v| {
                try writer.writeAll("'");
                // Basic escaping for single quotes
                for (v) |c| {
                    if (c == '\'') {
                        try writer.writeAll("''");
                    } else {
                        try writer.writeByte(c);
                    }
                }
                try writer.writeAll("'");
            },
            .blob => try writer.writeAll("?"),
            .null => try writer.writeAll("NULL"),
        }
    }
};

/// Build a SQL string with ? placeholders from a template and parameters.
/// For drivers that support true prepared statements, this returns the template as-is.
/// For debug/testing, formatParams can be used to produce an escaped string.
pub const ParamQuery = struct {
    allocator: std.mem.Allocator,
    sql_template: [:0]const u8,
    params: std.ArrayList(SqlParam),

    pub fn init(allocator: std.mem.Allocator, sql_template: [:0]const u8) ParamQuery {
        return .{
            .allocator = allocator,
            .sql_template = sql_template,
            .params = std.ArrayList(SqlParam).empty,
        };
    }

    pub fn deinit(self: *ParamQuery) void {
        self.params.deinit(self.allocator);
    }

    pub fn bindInt(self: *ParamQuery, value: i64) !void {
        try self.params.append(self.allocator, .{ .int = value });
    }

    pub fn bindReal(self: *ParamQuery, value: f64) !void {
        try self.params.append(self.allocator, .{ .real = value });
    }

    pub fn bindText(self: *ParamQuery, value: []const u8) !void {
        try self.params.append(self.allocator, .{ .text = value });
    }

    pub fn bindBlob(self: *ParamQuery, value: []const u8) !void {
        try self.params.append(self.allocator, .{ .blob = value });
    }

    pub fn bindNull(self: *ParamQuery) !void {
        try self.params.append(self.allocator, .null);
    }

    /// Format parameters into the SQL template for drivers that do not support
    /// native prepared statements. This is a fallback and less secure than true
    /// parameter binding.
    pub fn toSql(self: *ParamQuery) ![:0]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);

        var param_idx: usize = 0;
        var pos: usize = 0;
        while (pos < self.sql_template.len) {
            const q = std.mem.indexOfScalarPos(u8, self.sql_template, pos, '?') orelse {
                try result.appendSlice(self.allocator, self.sql_template[pos..]);
                break;
            };

            try result.appendSlice(self.allocator, self.sql_template[pos..q]);

            if (param_idx >= self.params.items.len) {
                return error.MissingParameter;
            }
            const param = self.params.items[param_idx];
            param_idx += 1;

            var buf: [256]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{f}", .{param});
            try result.appendSlice(self.allocator, s);

            pos = q + 1;
        }

        // Ensure null-terminated
        try result.append(self.allocator, 0);
        const slice = try result.toOwnedSlice(self.allocator);
        return slice[0 .. slice.len - 1 :0];
    }
};

test "ParamQuery basic" {
    const allocator = std.testing.allocator;

    var pq = ParamQuery.init(allocator, "SELECT * FROM users WHERE id = ? AND name = ?");
    defer pq.deinit();

    try pq.bindInt(42);
    try pq.bindText("alice");

    const sql = try pq.toSql();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = 42 AND name = 'alice'", sql);
}

test "ParamQuery text escaping" {
    const allocator = std.testing.allocator;

    var pq = ParamQuery.init(allocator, "INSERT INTO users (name) VALUES (?)");
    defer pq.deinit();

    try pq.bindText("O'Brien");

    const sql = try pq.toSql();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("INSERT INTO users (name) VALUES ('O''Brien')", sql);
}
