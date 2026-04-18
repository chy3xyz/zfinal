const std = @import("std");

/// URL 工具类
pub const UrlKit = struct {
    /// URL 编码
    pub fn encode(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);

        for (str) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try result.append(allocator, c);
            } else {
                var buf: [3]u8 = undefined;
                const hex = try std.fmt.bufPrint(&buf, "%{X:0>2}", .{c});
                try result.appendSlice(allocator, hex);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// URL 解码
    pub fn decode(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < str.len) {
            if (str[i] == '%' and i + 2 < str.len) {
                const hex = str[i + 1 .. i + 3];
                const byte = try std.fmt.parseInt(u8, hex, 16);
                try result.append(allocator, byte);
                i += 3;
            } else if (str[i] == '+') {
                try result.append(allocator, ' ');
                i += 1;
            } else {
                try result.append(allocator, str[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// 构建查询字符串
    pub fn buildQuery(allocator: std.mem.Allocator, params: std.StringHashMap([]const u8)) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);

        var it = params.iterator();
        var first = true;

        while (it.next()) |entry| {
            if (!first) {
                try result.append(allocator, '&');
            }
            first = false;

            const encoded_key = try encode(allocator, entry.key_ptr.*);
            defer allocator.free(encoded_key);

            const encoded_value = try encode(allocator, entry.value_ptr.*);
            defer allocator.free(encoded_value);

            try result.appendSlice(allocator, encoded_key);
            try result.append(allocator, '=');
            try result.appendSlice(allocator, encoded_value);
        }

        return result.toOwnedSlice(allocator);
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
