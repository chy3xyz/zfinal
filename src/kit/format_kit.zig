const std = @import("std");

/// 格式化工具类
pub const FormatKit = struct {
    /// 格式化文件大小
    pub fn formatFileSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
        const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
        var size: f64 = @floatFromInt(bytes);
        var unit_index: usize = 0;

        while (size >= 1024.0 and unit_index < units.len - 1) {
            size /= 1024.0;
            unit_index += 1;
        }

        if (unit_index == 0) {
            return try std.fmt.allocPrint(allocator, "{d} {s}", .{ bytes, units[unit_index] });
        } else {
            return try std.fmt.allocPrint(allocator, "{d:.2} {s}", .{ size, units[unit_index] });
        }
    }

    /// 格式化数字（千分位）
    pub fn formatNumber(allocator: std.mem.Allocator, number: i64) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        const num_str = try std.fmt.allocPrint(allocator, "{d}", .{@abs(number)});
        defer allocator.free(num_str);

        if (number < 0) {
            try result.append('-');
        }

        var count: usize = 0;
        var i: usize = num_str.len;
        while (i > 0) {
            i -= 1;
            if (count > 0 and count % 3 == 0) {
                try result.insert(0, ',');
            }
            try result.insert(0, num_str[i]);
            count += 1;
        }

        return result.toOwnedSlice();
    }

    /// 格式化百分比
    pub fn formatPercent(allocator: std.mem.Allocator, value: f64, precision: usize) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{d:.{d}}%", .{ value * 100, precision });
    }

    /// 格式化持续时间
    pub fn formatDuration(allocator: std.mem.Allocator, seconds: u64) ![]const u8 {
        const days = seconds / 86400;
        const hours = (seconds % 86400) / 3600;
        const minutes = (seconds % 3600) / 60;
        const secs = seconds % 60;

        if (days > 0) {
            return try std.fmt.allocPrint(allocator, "{d}d {d}h {d}m {d}s", .{ days, hours, minutes, secs });
        } else if (hours > 0) {
            return try std.fmt.allocPrint(allocator, "{d}h {d}m {d}s", .{ hours, minutes, secs });
        } else if (minutes > 0) {
            return try std.fmt.allocPrint(allocator, "{d}m {d}s", .{ minutes, secs });
        } else {
            return try std.fmt.allocPrint(allocator, "{d}s", .{secs});
        }
    }

    /// 截断字符串
    pub fn truncate(allocator: std.mem.Allocator, str: []const u8, max_len: usize, suffix: []const u8) ![]const u8 {
        if (str.len <= max_len) {
            return try allocator.dupe(u8, str);
        }

        const truncated_len = if (max_len > suffix.len) max_len - suffix.len else 0;
        var result = try allocator.alloc(u8, truncated_len + suffix.len);

        @memcpy(result[0..truncated_len], str[0..truncated_len]);
        @memcpy(result[truncated_len..], suffix);

        return result;
    }
};

test "FormatKit formatFileSize" {
    const allocator = std.testing.allocator;

    const size1 = try FormatKit.formatFileSize(allocator, 1024);
    defer allocator.free(size1);
    try std.testing.expect(std.mem.indexOf(u8, size1, "KB") != null);

    const size2 = try FormatKit.formatFileSize(allocator, 1024 * 1024);
    defer allocator.free(size2);
    try std.testing.expect(std.mem.indexOf(u8, size2, "MB") != null);
}

test "FormatKit formatNumber" {
    const allocator = std.testing.allocator;

    const num = try FormatKit.formatNumber(allocator, 1234567);
    defer allocator.free(num);
    try std.testing.expectEqualStrings("1,234,567", num);
}
