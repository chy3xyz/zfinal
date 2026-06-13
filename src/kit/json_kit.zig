const std = @import("std");

/// Maximum JSON nesting depth to prevent stack overflow from malicious input.
pub const MAX_JSON_DEPTH = 64;

/// JSON 工具类
pub const JsonKit = struct {
    /// 解析 JSON 字符串 (with depth limit)
    pub fn parse(comptime T: type, allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(T) {
        if (!validateDepth(json_str, MAX_JSON_DEPTH)) return error.JsonNestingTooDeep;
        return std.json.parseFromSlice(T, allocator, json_str, .{});
    }

    /// Validate JSON nesting depth without full parsing.
    pub fn validateDepth(json_str: []const u8, max_depth: usize) bool {
        var depth: usize = 0;
        var in_string = false;
        var escaped = false;
        for (json_str) |c| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\' and in_string) {
                escaped = true;
                continue;
            }
            if (c == '"') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;
            if (c == '{' or c == '[') {
                depth += 1;
                if (depth > max_depth) return false;
            }
            if (c == '}' or c == ']') {
                if (depth > 0) depth -= 1;
            }
        }
        return true;
    }

    /// 序列化为 JSON 字符串
    pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();

        try std.json.Stringify.value(value, .{}, &out.writer);
        return out.toOwnedSlice();
    }

    /// 美化 JSON 字符串
    pub fn prettify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();

        try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
        return out.toOwnedSlice();
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

test "JsonKit parse array" {
    const a = std.testing.allocator;
    const json = "[1, 2, 3]";
    const parsed = try std.json.parseFromSlice([]i32, a, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.len);
}

test "JsonKit null and bool" {
    const a = std.testing.allocator;
    const json = "{\"active\": true, \"deleted\": false}";
    const S = struct { active: bool, deleted: bool };
    const parsed = try JsonKit.parse(S, a, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.active);
    try std.testing.expect(!parsed.value.deleted);
}
