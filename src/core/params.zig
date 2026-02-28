const std = @import("std");

/// Parse query string into a StringHashMap
pub fn parseQuery(allocator: std.mem.Allocator, query: []const u8) !std.StringHashMap([]const u8) {
    var params = std.StringHashMap([]const u8).init(allocator);
    try parseQueryIntoAllocator(allocator, query, &params);
    return params;
}

pub fn parseQueryIntoAllocator(allocator: std.mem.Allocator, query: []const u8, params: *std.StringHashMap([]const u8)) !void {
    if (query.len == 0) return;

    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;

        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];

            // URL decode both key and value
            const decoded_key = try urlDecode(allocator, key);
            const decoded_value = try urlDecode(allocator, value);

            try params.put(decoded_key, decoded_value);
        } else {
            // No value, just key
            const decoded_key = try urlDecode(allocator, pair);
            try params.put(decoded_key, "");
        }
    }
}

/// Simple URL decoder (handles %XX encoding)
fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            // Decode %XX
            const hex = input[i + 1 .. i + 3];
            const value = std.fmt.parseInt(u8, hex, 16) catch {
                // Invalid hex, just keep the %
                try result.append('%');
                i += 1;
                continue;
            };
            try result.append(value);
            i += 3;
        } else if (input[i] == '+') {
            // + is space in URL encoding
            try result.append(' ');
            i += 1;
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Convert string to int with optional default
pub fn toInt(value: ?[]const u8, default_value: ?i32) !?i32 {
    if (value) |v| {
        if (v.len == 0) return default_value;
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len == 0) return default_value;

        return std.fmt.parseInt(i32, trimmed, 10) catch |err| {
            return err;
        };
    }
    return default_value;
}

/// Convert string to long (i64) with optional default
pub fn toLong(value: ?[]const u8, default_value: ?i64) !?i64 {
    if (value) |v| {
        if (v.len == 0) return default_value;
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len == 0) return default_value;

        return std.fmt.parseInt(i64, trimmed, 10) catch |err| {
            return err;
        };
    }
    return default_value;
}

/// Convert string to boolean with optional default
/// "1", "true", "yes" -> true
/// "0", "false", "no" -> false
pub fn toBoolean(value: ?[]const u8, default_value: ?bool) ?bool {
    if (value) |v| {
        if (v.len == 0) return default_value;
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len == 0) return default_value;

        // Convert to lowercase for comparison
        var lower_buf: [32]u8 = undefined;
        if (trimmed.len > lower_buf.len) return default_value;

        const lower = std.ascii.lowerString(&lower_buf, trimmed);

        if (std.mem.eql(u8, lower, "1") or
            std.mem.eql(u8, lower, "true") or
            std.mem.eql(u8, lower, "yes"))
        {
            return true;
        } else if (std.mem.eql(u8, lower, "0") or
            std.mem.eql(u8, lower, "false") or
            std.mem.eql(u8, lower, "no"))
        {
            return false;
        }

        return default_value;
    }
    return default_value;
}

test "parseQuery basic" {
    const allocator = std.testing.allocator;

    var params = try parseQuery(allocator, "name=John&age=25");
    defer params.deinit();

    try std.testing.expectEqualStrings("John", params.get("name").?);
    try std.testing.expectEqualStrings("25", params.get("age").?);
}

test "parseQuery with url encoding" {
    const allocator = std.testing.allocator;

    var params = try parseQuery(allocator, "msg=Hello+World&email=test%40example.com");
    defer params.deinit();

    try std.testing.expectEqualStrings("Hello World", params.get("msg").?);
    try std.testing.expectEqualStrings("test@example.com", params.get("email").?);
}

test "toInt conversion" {
    try std.testing.expectEqual(@as(?i32, 42), try toInt("42", null));
    try std.testing.expectEqual(@as(?i32, 0), try toInt("0", null));
    try std.testing.expectEqual(@as(?i32, -10), try toInt("-10", null));
    try std.testing.expectEqual(@as(?i32, 99), try toInt(null, 99));
    try std.testing.expectEqual(@as(?i32, 99), try toInt("", 99));
}

test "toLong conversion" {
    try std.testing.expectEqual(@as(?i64, 1234567890), try toLong("1234567890", null));
    try std.testing.expectEqual(@as(?i64, 999), try toLong(null, 999));
}

test "toBoolean conversion" {
    try std.testing.expectEqual(@as(?bool, true), toBoolean("true", null));
    try std.testing.expectEqual(@as(?bool, true), toBoolean("1", null));
    try std.testing.expectEqual(@as(?bool, true), toBoolean("YES", null));
    try std.testing.expectEqual(@as(?bool, false), toBoolean("false", null));
    try std.testing.expectEqual(@as(?bool, false), toBoolean("0", null));
    try std.testing.expectEqual(@as(?bool, false), toBoolean("no", null));
    try std.testing.expectEqual(@as(?bool, true), toBoolean(null, true));
}
