const std = @import("std");

/// 正则表达式工具类（简化版）
pub const RegexKit = struct {
    /// 检查是否匹配模式（简单通配符）
    pub fn match(pattern: []const u8, text: []const u8) bool {
        return matchImpl(pattern, text, 0, 0);
    }

    fn matchImpl(pattern: []const u8, text: []const u8, p_idx: usize, t_idx: usize) bool {
        // 模式结束
        if (p_idx >= pattern.len) {
            return t_idx >= text.len;
        }

        // 通配符 *
        if (pattern[p_idx] == '*') {
            // 匹配 0 个或多个字符
            if (matchImpl(pattern, text, p_idx + 1, t_idx)) return true;
            if (t_idx < text.len and matchImpl(pattern, text, p_idx, t_idx + 1)) return true;
            return false;
        }

        // 通配符 ?
        if (pattern[p_idx] == '?') {
            if (t_idx >= text.len) return false;
            return matchImpl(pattern, text, p_idx + 1, t_idx + 1);
        }

        // 普通字符
        if (t_idx >= text.len or pattern[p_idx] != text[t_idx]) {
            return false;
        }

        return matchImpl(pattern, text, p_idx + 1, t_idx + 1);
    }

    /// 提取所有数字
    pub fn extractNumbers(allocator: std.mem.Allocator, text: []const u8) ![]i64 {
        var result = std.ArrayList(i64).init(allocator);
        defer result.deinit();

        var i: usize = 0;
        while (i < text.len) {
            if (std.ascii.isDigit(text[i]) or (text[i] == '-' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
                var j = i + 1;
                while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) {}

                const num_str = text[i..j];
                const num = try std.fmt.parseInt(i64, num_str, 10);
                try result.append(num);

                i = j;
            } else {
                i += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// 检查是否是邮箱格式
    pub fn isEmail(email: []const u8) bool {
        const at_pos = std.mem.indexOf(u8, email, "@") orelse return false;
        const dot_pos = std.mem.lastIndexOf(u8, email, ".") orelse return false;

        return at_pos > 0 and dot_pos > at_pos + 1 and dot_pos < email.len - 1;
    }

    /// 检查是否是 URL 格式
    pub fn isUrl(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://") or
            std.mem.startsWith(u8, url, "ftp://");
    }
};

test "RegexKit match" {
    try std.testing.expect(RegexKit.match("hello", "hello"));
    try std.testing.expect(RegexKit.match("h?llo", "hello"));
    try std.testing.expect(RegexKit.match("h*o", "hello"));
    try std.testing.expect(!RegexKit.match("hello", "world"));
}

test "RegexKit isEmail" {
    try std.testing.expect(RegexKit.isEmail("test@example.com"));
    try std.testing.expect(!RegexKit.isEmail("invalid.email"));
}
