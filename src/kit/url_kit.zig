const std = @import("std");

/// URL 工具类
pub const UrlKit = struct {
    /// URL 编码
    pub fn encode(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        for (str) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try result.append(c);
            } else {
                try result.writer().print("%{X:0>2}", .{c});
            }
        }

        return result.toOwnedSlice();
    }

    /// URL 解码
    pub fn decode(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        var i: usize = 0;
        while (i < str.len) {
            if (str[i] == '%' and i + 2 < str.len) {
                const hex = str[i + 1 .. i + 3];
                const byte = try std.fmt.parseInt(u8, hex, 16);
                try result.append(byte);
                i += 3;
            } else if (str[i] == '+') {
                try result.append(' ');
                i += 1;
            } else {
                try result.append(str[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// 构建查询字符串
    pub fn buildQuery(allocator: std.mem.Allocator, params: std.StringHashMap([]const u8)) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        var it = params.iterator();
        var first = true;

        while (it.next()) |entry| {
            if (!first) {
                try result.append('&');
            }
            first = false;

            const encoded_key = try encode(allocator, entry.key_ptr.*);
            defer allocator.free(encoded_key);

            const encoded_value = try encode(allocator, entry.value_ptr.*);
            defer allocator.free(encoded_value);

            try result.appendSlice(encoded_key);
            try result.append('=');
            try result.appendSlice(encoded_value);
        }

        return result.toOwnedSlice();
    }
};

test "UrlKit encode and decode" {
    const allocator = std.testing.allocator;

    const original = "Hello World!";
    const encoded = try UrlKit.encode(allocator, original);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("Hello%20World%21", encoded);

    const decoded = try UrlKit.decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}
