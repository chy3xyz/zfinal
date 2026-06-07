const std = @import("std");
const SqlParam = @import("sql_param.zig").SqlParam;

/// 渲染结果类型
pub const RenderResult = struct {
    sql: [:0]const u8,
    params: []const SqlParam,
};

/// SQL 模板引擎（参数化查询版本）
/// 支持 {param} 风格的命名参数，最终输出带 ? 占位符的 SQL 和参数列表
pub const SqlTemplate = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SqlTemplate {
        return SqlTemplate{ .allocator = allocator };
    }

    /// 渲染 SQL 模板为参数化查询
    /// 返回：sql_template（带 ? 占位符） + params 数组
    pub fn render(self: *SqlTemplate, template: []const u8, params_struct: anytype) !RenderResult {
        var sql_parts = std.ArrayList(u8).empty;
        defer sql_parts.deinit(self.allocator);

        var param_list = std.ArrayList(SqlParam).empty;
        defer param_list.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < template.len) {
            const start = std.mem.indexOfScalarPos(u8, template, pos, '{') orelse {
                try sql_parts.appendSlice(self.allocator, template[pos..]);
                break;
            };

            try sql_parts.appendSlice(self.allocator, template[pos..start]);

            const end = std.mem.indexOfScalarPos(u8, template, start, '}') orelse {
                return error.UnclosedBrace;
            };

            const param_name = template[start + 1 .. end];
            const value = try self.getParamValue(params_struct, param_name);
            try param_list.append(self.allocator, value);
            try sql_parts.appendSlice(self.allocator, "?");

            pos = end + 1;
        }

        try sql_parts.append(self.allocator, 0);
        const sql_slice = try sql_parts.toOwnedSlice(self.allocator);
        const sql_z = sql_slice[0 .. sql_slice.len - 1 :0];

        const params_slice = try param_list.toOwnedSlice(self.allocator);

        return .{ .sql = sql_z, .params = params_slice };
    }

    /// 从参数结构中获取值
    fn getParamValue(self: *SqlTemplate, params: anytype, name: []const u8) !SqlParam {
        _ = self;
        const T = @TypeOf(params);
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") {
            return error.InvalidParamsType;
        }

        inline for (type_info.@"struct".field_names) |fname| {
            if (std.mem.eql(u8, fname, name)) {
                const value = @field(params, fname);
                return sqlParamFromValue(value);
            }
        }

        return error.ParamNotFound;
    }

    fn sqlParamFromValue(value: anytype) SqlParam {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .int, .comptime_int => .{ .int = @intCast(value) },
            .float, .comptime_float => .{ .real = @floatCast(value) },
            .bool => .{ .int = if (value) 1 else 0 },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return .{ .text = value };
                }
                if (ptr_info.size == .one) {
                    const child_info = @typeInfo(ptr_info.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        return .{ .text = value };
                    }
                }
                @compileError("Unsupported parameter type for SQL template");
            },
            else => @compileError("Unsupported parameter type for SQL template"),
        };
    }
};

/// 命名 SQL 模板管理器
pub const SqlTemplateManager = struct {
    templates: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SqlTemplateManager {
        return SqlTemplateManager{
            .templates = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SqlTemplateManager) void {
        var it = self.templates.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.templates.deinit();
    }

    /// 添加模板
    pub fn add(self: *SqlTemplateManager, name: []const u8, template: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const template_copy = try self.allocator.dupe(u8, template);
        try self.templates.put(name_copy, template_copy);
    }

    /// 获取模板
    pub fn get(self: *SqlTemplateManager, name: []const u8) ?[]const u8 {
        return self.templates.get(name);
    }

    /// 渲染模板为参数化查询
    pub fn render(self: *SqlTemplateManager, name: []const u8, params: anytype) !RenderResult {
        const template = self.get(name) orelse return error.TemplateNotFound;
        var engine = SqlTemplate.init(self.allocator);
        return try engine.render(template, params);
    }
};

test "sql template basic" {
    const allocator = std.testing.allocator;

    var engine = SqlTemplate.init(allocator);

    const result = try engine.render("SELECT * FROM users WHERE age > {age} AND city = {city}", .{ .age = 18, .city = "Beijing" });
    defer allocator.free(result.sql);
    defer allocator.free(result.params);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE age > ? AND city = ?", result.sql);
    try std.testing.expectEqual(@as(usize, 2), result.params.len);
    try std.testing.expectEqual(@as(i64, 18), result.params[0].int);
    try std.testing.expectEqualStrings("Beijing", result.params[1].text);
}

test "sql template manager" {
    const allocator = std.testing.allocator;

    var manager = SqlTemplateManager.init(allocator);
    defer manager.deinit();

    try manager.add("find_user", "SELECT * FROM users WHERE id = {id}");

    const result = try manager.render("find_user", .{ .id = 123 });
    defer allocator.free(result.sql);
    defer allocator.free(result.params);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = ?", result.sql);
    try std.testing.expectEqual(@as(i64, 123), result.params[0].int);
}
