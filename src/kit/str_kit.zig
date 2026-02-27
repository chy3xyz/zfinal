const std = @import("std");

/// 字符串工具类（参考 JFinal StrKit）
pub const StrKit = struct {
    /// 检查字符串是否为空或 null
    pub fn isBlank(str: ?[]const u8) bool {
        if (str == null) return true;
        const s = str.?;
        if (s.len == 0) return true;

        for (s) |c| {
            if (!std.ascii.isWhitespace(c)) return false;
        }
        return true;
    }

    /// 检查字符串是否非空
    pub fn notBlank(str: ?[]const u8) bool {
        return !isBlank(str);
    }

    /// 去除首尾空白
    pub fn trim(str: []const u8) []const u8 {
        return std.mem.trim(u8, str, &std.ascii.whitespace);
    }

    /// 分割字符串
    pub fn split(allocator: std.mem.Allocator, str: []const u8, delimiter: []const u8) ![][]const u8 {
        var result = std.ArrayList([]const u8).init(allocator);
        defer result.deinit();

        var it = std.mem.splitSequence(u8, str, delimiter);
        while (it.next()) |part| {
            try result.append(part);
        }

        return result.toOwnedSlice();
    }

    /// 连接字符串数组
    pub fn join(allocator: std.mem.Allocator, parts: []const []const u8, separator: []const u8) ![]const u8 {
        return std.mem.join(allocator, separator, parts);
    }

    /// 首字母大写
    pub fn capitalize(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        if (str.len == 0) return try allocator.dupe(u8, str);

        var result = try allocator.alloc(u8, str.len);
        result[0] = std.ascii.toUpper(str[0]);
        @memcpy(result[1..], str[1..]);

        return result;
    }

    /// 转小写
    pub fn toLower(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        return std.ascii.allocLowerString(allocator, str);
    }

    /// 转大写
    pub fn toUpper(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        return std.ascii.allocUpperString(allocator, str);
    }

    /// 检查是否包含子串
    pub fn contains(str: []const u8, substr: []const u8) bool {
        return std.mem.indexOf(u8, str, substr) != null;
    }

    /// 替换字符串
    pub fn replace(allocator: std.mem.Allocator, str: []const u8, old: []const u8, new: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        var pos: usize = 0;
        while (pos < str.len) {
            if (std.mem.startsWith(u8, str[pos..], old)) {
                try result.appendSlice(new);
                pos += old.len;
            } else {
                try result.append(str[pos]);
                pos += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// 填充字符串（左侧）
    pub fn padLeft(allocator: std.mem.Allocator, str: []const u8, length: usize, pad_char: u8) ![]const u8 {
        if (str.len >= length) return try allocator.dupe(u8, str);

        const pad_len = length - str.len;
        var result = try allocator.alloc(u8, length);

        @memset(result[0..pad_len], pad_char);
        @memcpy(result[pad_len..], str);

        return result;
    }

    /// 填充字符串（右侧）
    pub fn padRight(allocator: std.mem.Allocator, str: []const u8, length: usize, pad_char: u8) ![]const u8 {
        if (str.len >= length) return try allocator.dupe(u8, str);

        var result = try allocator.alloc(u8, length);

        @memcpy(result[0..str.len], str);
        @memset(result[str.len..], pad_char);

        return result;
    }
};

test "StrKit isBlank" {
    try std.testing.expect(StrKit.isBlank(null));
    try std.testing.expect(StrKit.isBlank(""));
    try std.testing.expect(StrKit.isBlank("   "));
    try std.testing.expect(!StrKit.isBlank("hello"));
}

test "StrKit split and join" {
    const allocator = std.testing.allocator;

    const parts = try StrKit.split(allocator, "a,b,c", ",");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);

    const joined = try StrKit.join(allocator, parts, "-");
    defer allocator.free(joined);

    try std.testing.expectEqualStrings("a-b-c", joined);
}
