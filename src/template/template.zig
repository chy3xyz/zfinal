const std = @import("std");

/// 简单的模板引擎
/// 支持变量替换 {{variable}} 和简单的控制结构
pub const Template = struct {
    allocator: std.mem.Allocator,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) Template {
        return .{
            .allocator = allocator,
            .content = content,
        };
    }

    /// 从文件加载模板
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Template {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        return Template{
            .allocator = allocator,
            .content = content,
        };
    }

    /// 渲染模板
    pub fn render(self: *Template, data: anytype) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var pos: usize = 0;
        while (pos < self.content.len) {
            // 查找 {{
            const start = std.mem.indexOfPos(u8, self.content, pos, "{{") orelse {
                // 没有更多变量，添加剩余内容
                try result.appendSlice(self.content[pos..]);
                break;
            };

            // 添加 {{ 之前的内容
            try result.appendSlice(self.content[pos..start]);

            // 查找 }}
            const end = std.mem.indexOfPos(u8, self.content, start, "}}") orelse {
                return error.UnclosedBrace;
            };

            // 提取变量名
            const var_name = std.mem.trim(u8, self.content[start + 2 .. end], &std.ascii.whitespace);

            // 获取变量值并替换
            const value = try self.getFieldValue(data, var_name);
            defer self.allocator.free(value);
            try result.appendSlice(value);

            pos = end + 2;
        }

        return result.toOwnedSlice();
    }

    /// 从数据结构中获取字段值
    fn getFieldValue(self: *Template, data: anytype, field_name: []const u8) ![]const u8 {
        const T = @TypeOf(data);
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") {
            return error.InvalidDataType;
        }

        inline for (type_info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                const value = @field(data, field.name);
                return try self.formatValue(value);
            }
        }

        return error.FieldNotFound;
    }

    /// 格式化值为字符串
    fn formatValue(self: *Template, value: anytype) ![]const u8 {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .int, .comptime_int => try std.fmt.allocPrint(self.allocator, "{d}", .{value}),
            .float, .comptime_float => try std.fmt.allocPrint(self.allocator, "{d}", .{value}),
            .bool => if (value) try self.allocator.dupe(u8, "true") else try self.allocator.dupe(u8, "false"),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return try self.allocator.dupe(u8, value);
                }
                return error.UnsupportedType;
            },
            .optional => |_| {
                if (value) |v| {
                    return try self.formatValue(v);
                } else {
                    return try self.allocator.dupe(u8, "");
                }
            },
            else => error.UnsupportedType,
        };
    }

    pub fn deinit(self: *Template) void {
        self.allocator.free(self.content);
    }
};

/// 模板管理器
pub const TemplateManager = struct {
    templates: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    template_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, template_dir: []const u8) !TemplateManager {
        return TemplateManager{
            .templates = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .template_dir = try allocator.dupe(u8, template_dir),
        };
    }

    pub fn deinit(self: *TemplateManager) void {
        var it = self.templates.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.templates.deinit();
        self.allocator.free(self.template_dir);
    }

    /// 加载模板
    pub fn load(self: *TemplateManager, name: []const u8) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.template_dir, name });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        const name_copy = try self.allocator.dupe(u8, name);

        try self.templates.put(name_copy, content);
    }

    /// 渲染模板
    pub fn render(self: *TemplateManager, name: []const u8, data: anytype) ![]const u8 {
        const content = self.templates.get(name) orelse {
            // 尝试加载模板
            try self.load(name);
            return self.render(name, data);
        };

        var template = Template.init(self.allocator, content);
        return try template.render(data);
    }
};

test "Template basic" {
    const allocator = std.testing.allocator;

    const html = "Hello, {{name}}! You are {{age}} years old.";
    var template = Template.init(allocator, html);

    const data = .{
        .name = "Alice",
        .age = 25,
    };

    const result = try template.render(data);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, Alice! You are 25 years old.", result);
}
