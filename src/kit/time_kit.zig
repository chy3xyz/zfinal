const std = @import("std");

/// 时间工具类
pub const TimeKit = struct {
    /// 获取当前时间戳（秒）
    pub fn now() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return @as(i64, ts.sec);
    }

    /// 获取当前时间戳（毫秒）
    pub fn nowMillis() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
    }

    /// 格式化时间戳为字符串（ISO 8601）
    pub fn format(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }

    /// 睡眠（毫秒）
    pub fn sleep(millis: u64) void {
        const io_instance = @import("../io_instance.zig");
        std.Io.sleep(io_instance.io, std.Io.Duration.fromMilliseconds(millis), .awake) catch {};
    }
};

test "TimeKit now" {
    const ts = TimeKit.now();
    try std.testing.expect(ts > 0);
}

test "TimeKit format" {
    const allocator = std.testing.allocator;

    const formatted = try TimeKit.format(allocator, 1609459200); // 2021-01-01 00:00:00
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.startsWith(u8, formatted, "2021-01-01"));
}
