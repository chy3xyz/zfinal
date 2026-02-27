const std = @import("std");

/// JSON 工具类
pub const JsonKit = struct {
    /// 解析 JSON 字符串
    pub fn parse(comptime T: type, allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, json_str, .{});
    }

    /// 序列化为 JSON 字符串
    pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        try std.json.stringify(value, .{}, list.writer());
        return list.toOwnedSlice();
    }

    /// 美化 JSON 字符串
    pub fn prettify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        try std.json.stringify(value, .{ .whitespace = .indent_2 }, list.writer());
        return list.toOwnedSlice();
    }
};

test "JsonKit parse and stringify" {
    const allocator = std.testing.allocator;

    const TestStruct = struct {
        name: []const u8,
        age: i32,
    };

    const json_str = "{\"name\":\"Alice\",\"age\":25}";

    const parsed = try JsonKit.parse(TestStruct, allocator, json_str);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqual(@as(i32, 25), parsed.value.age);

    const stringified = try JsonKit.stringify(allocator, parsed.value);
    defer allocator.free(stringified);

    try std.testing.expect(std.mem.indexOf(u8, stringified, "Alice") != null);
}
