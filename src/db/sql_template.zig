const std = @import("std");

/// SQL 模板引擎（简化版）
pub const SqlTemplate = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SqlTemplate {
        return SqlTemplate{ .allocator = allocator };
    }

    /// 渲染 SQL 模板
    /// 支持 {param} 风格的参数替换
    pub fn render(self: *SqlTemplate, template: []const u8, params: anytype) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < template.len) {
            // 查找 {
            const start = std.mem.indexOfScalarPos(u8, template, pos, '{') orelse {
                // 没有更多参数，添加剩余部分
                try result.appendSlice(self.allocator, template[pos..]);
                break;
            };

            // 添加 { 之前的内容
            try result.appendSlice(self.allocator, template[pos..start]);

            // 查找 }
            const end = std.mem.indexOfScalarPos(u8, template, start, '}') orelse {
                return error.UnclosedBrace;
            };

            // 提取参数名
            const param_name = template[start + 1 .. end];

            // 获取参数值并替换
            const value = try self.getParamValue(params, param_name);
            defer self.allocator.free(value);
            try result.appendSlice(self.allocator, value);

            pos = end + 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// 从参数结构中获取值
    fn getParamValue(self: *SqlTemplate, params: anytype, name: []const u8) ![]const u8 {
        const T = @TypeOf(params);
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") {
            return error.InvalidParamsType;
        }

        inline for (type_info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                const value = @field(params, field.name);
                return self.formatValue(value);
            }
        }

        return error.ParamNotFound;
    }

    /// 格式化值为 SQL 字符串
    fn formatValue(self: *SqlTemplate, value: anytype) ![]const u8 {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .int, .comptime_int => {
                return try std.fmt.allocPrint(self.allocator, "{d}", .{value});
            },
            .float, .comptime_float => {
                return try std.fmt.allocPrint(self.allocator, "{d}", .{value});
            },
            .bool => if (value) try self.allocator.dupe(u8, "true") else try self.allocator.dupe(u8, "false"),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return try self.allocator.dupe(u8, value);
                }
                if (ptr_info.size == .one) {
                    const child_info = @typeInfo(ptr_info.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        return try self.allocator.dupe(u8, value);
                    }
                }
                return error.UnsupportedType;
            },
            else => error.UnsupportedType,
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

    /// 渲染模板
    pub fn render(self: *SqlTemplateManager, name: []const u8, params: anytype) ![]const u8 {
        const template = self.get(name) orelse return error.TemplateNotFound;
        var engine = SqlTemplate.init(self.allocator);
        return try engine.render(template, params);
    }
};

test "sql template basic" {
    const allocator = std.testing.allocator;

    var engine = SqlTemplate.init(allocator);

    const sql = try engine.render("SELECT * FROM users WHERE age > {age} AND city = '{city}'", .{ .age = 18, .city = "Beijing" });
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE age > 18 AND city = 'Beijing'", sql);
}

test "sql template manager" {
    const allocator = std.testing.allocator;

    var manager = SqlTemplateManager.init(allocator);
    defer manager.deinit();

    try manager.add("find_user", "SELECT * FROM users WHERE id = {id}");

    const sql = try manager.render("find_user", .{ .id = 123 });
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = 123", sql);
}
