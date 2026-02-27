const std = @import("std");

/// 配置管理器
pub const Config = struct {
    data: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .data = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    /// 从文件加载配置（支持 .ini 和 .json）
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        var config = Config.init(allocator);
        errdefer config.deinit();

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(content);

        // 根据扩展名选择解析器
        if (std.mem.endsWith(u8, path, ".json")) {
            try config.parseJson(content);
        } else {
            try config.parseIni(content);
        }

        return config;
    }

    /// 解析 INI 格式
    fn parseIni(self: *Config, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            // 跳过空行和注释
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

            // 跳过 section headers [section]
            if (trimmed[0] == '[') continue;

            // 解析 key=value
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

                const key_copy = try self.allocator.dupe(u8, key);
                const value_copy = try self.allocator.dupe(u8, value);

                try self.data.put(key_copy, value_copy);
            }
        }
    }

    /// 解析 JSON 格式（简化版）
    fn parseJson(self: *Config, content: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidJson;

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);

            const value_str = switch (entry.value_ptr.*) {
                .string => |s| try self.allocator.dupe(u8, s),
                .integer => |i| try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
                .float => |f| try std.fmt.allocPrint(self.allocator, "{d}", .{f}),
                .bool => |b| try self.allocator.dupe(u8, if (b) "true" else "false"),
                else => try self.allocator.dupe(u8, ""),
            };

            try self.data.put(key_copy, value_str);
        }
    }

    /// 获取配置值
    pub fn get(self: *const Config, key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }

    /// 获取配置值（带默认值）
    pub fn getDefault(self: *const Config, key: []const u8, default_value: []const u8) []const u8 {
        return self.data.get(key) orelse default_value;
    }

    /// 获取整数配置
    pub fn getInt(self: *const Config, key: []const u8) !?i64 {
        const value = self.get(key) orelse return null;
        return try std.fmt.parseInt(i64, value, 10);
    }

    /// 获取布尔配置
    pub fn getBool(self: *const Config, key: []const u8) !?bool {
        const value = self.get(key) orelse return null;
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) return true;
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) return false;
        return error.InvalidBool;
    }

    /// 设置配置值
    pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.data.put(key_copy, value_copy);
    }
};

test "config ini parsing" {
    const allocator = std.testing.allocator;

    const ini_content =
        \\# This is a comment
        \\[server]
        \\port = 8080
        \\host = localhost
        \\
        \\[database]
        \\driver = sqlite
    ;

    var config = Config.init(allocator);
    defer config.deinit();

    try config.parseIni(ini_content);

    try std.testing.expectEqualStrings("8080", config.get("port").?);
    try std.testing.expectEqualStrings("localhost", config.get("host").?);
    try std.testing.expectEqualStrings("sqlite", config.get("driver").?);
}

test "config json parsing" {
    const allocator = std.testing.allocator;

    const json_content =
        \\{
        \\  "port": 8080,
        \\  "host": "localhost",
        \\  "debug": true
        \\}
    ;

    var config = Config.init(allocator);
    defer config.deinit();

    try config.parseJson(json_content);

    try std.testing.expectEqualStrings("8080", config.get("port").?);
    try std.testing.expectEqualStrings("localhost", config.get("host").?);
    try std.testing.expectEqualStrings("true", config.get("debug").?);
}
