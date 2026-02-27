const std = @import("std");

/// 数字工具类
pub const NumberKit = struct {
    /// 安全转换为整数
    pub fn toInt(str: []const u8, default_value: i64) i64 {
        return std.fmt.parseInt(i64, str, 10) catch default_value;
    }

    /// 安全转换为浮点数
    pub fn toFloat(str: []const u8, default_value: f64) f64 {
        return std.fmt.parseFloat(f64, str) catch default_value;
    }

    /// 格式化整数
    pub fn formatInt(allocator: std.mem.Allocator, value: i64) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{d}", .{value});
    }

    /// 格式化浮点数
    pub fn formatFloat(allocator: std.mem.Allocator, value: f64, precision: usize) ![]const u8 {
        var buf: [64]u8 = undefined;
        const fmt_str = try std.fmt.bufPrint(&buf, "{{d:.{d}}}", .{precision});
        return try std.fmt.allocPrint(allocator, fmt_str, .{value});
    }

    /// 限制数值范围
    pub fn clamp(comptime T: type, value: T, min_val: T, max_val: T) T {
        return @max(min_val, @min(max_val, value));
    }

    /// 检查是否在范围内
    pub fn inRange(comptime T: type, value: T, min_val: T, max_val: T) bool {
        return value >= min_val and value <= max_val;
    }
};

test "NumberKit toInt" {
    try std.testing.expectEqual(@as(i64, 123), NumberKit.toInt("123", 0));
    try std.testing.expectEqual(@as(i64, 0), NumberKit.toInt("invalid", 0));
}

test "NumberKit clamp" {
    try std.testing.expectEqual(@as(i32, 5), NumberKit.clamp(i32, 3, 5, 10));
    try std.testing.expectEqual(@as(i32, 7), NumberKit.clamp(i32, 7, 5, 10));
    try std.testing.expectEqual(@as(i32, 10), NumberKit.clamp(i32, 15, 5, 10));
}
