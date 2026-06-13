const std = @import("std");

/// 时间工具类（合并 DateKit）
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

    // === Date utilities (merged from DateKit) ===

    pub const Date = struct {
        year: i32,
        month: u8,
        day: u8,
        hour: u8 = 0,
        minute: u8 = 0,
        second: u8 = 0,

        pub fn format(self: Date, allocator: std.mem.Allocator, fmt: []const u8) ![]const u8 {
            var result = std.ArrayList(u8).empty;
            defer result.deinit(allocator);
            var i: usize = 0;
            while (i < fmt.len) {
                if (fmt[i] == '%' and i + 1 < fmt.len) {
                    var buf: [16]u8 = undefined;
                    const slice = switch (fmt[i + 1]) {
                        'Y' => try std.fmt.bufPrint(&buf, "{d:0>4}", .{self.year}),
                        'y' => try std.fmt.bufPrint(&buf, "{d:0>2}", .{@mod(self.year, 100)}),
                        'm' => try std.fmt.bufPrint(&buf, "{d:0>2}", .{self.month}),
                        'd' => try std.fmt.bufPrint(&buf, "{d:0>2}", .{self.day}),
                        'H' => try std.fmt.bufPrint(&buf, "{d:0>2}", .{self.hour}),
                        'M' => try std.fmt.bufPrint(&buf, "{d:0>2}", .{self.minute}),
                        'S' => try std.fmt.bufPrint(&buf, "{d:0>2}", .{self.second}),
                        else => blk: {
                            buf[0] = fmt[i + 1];
                            break :blk buf[0..1];
                        },
                    };
                    try result.appendSlice(allocator, slice);
                    i += 2;
                } else {
                    try result.append(allocator, fmt[i]);
                    i += 1;
                }
            }
            return result.toOwnedSlice(allocator);
        }
    };

    pub fn nowDate() Date {
        return fromTimestamp(now());
    }

    pub fn fromTimestamp(timestamp: i64) Date {
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const ds = es.getDaySeconds();
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        return Date{ .year = yd.year, .month = md.month.numeric(), .day = md.day_index + 1, .hour = ds.getHoursIntoDay(), .minute = ds.getMinutesIntoHour(), .second = ds.getSecondsIntoMinute() };
    }

    pub fn isLeapYear(year: i32) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
    }

    pub fn daysInMonth(year: i32, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) 29 else 28,
            else => 0,
        };
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

test "TimeKit isLeapYear" {
    try std.testing.expect(TimeKit.isLeapYear(2020));
    try std.testing.expect(!TimeKit.isLeapYear(2021));
    try std.testing.expect(TimeKit.isLeapYear(2000));
    try std.testing.expect(!TimeKit.isLeapYear(1900));
}

test "TimeKit daysInMonth" {
    try std.testing.expectEqual(@as(u8, 31), TimeKit.daysInMonth(2021, 1));
    try std.testing.expectEqual(@as(u8, 28), TimeKit.daysInMonth(2021, 2));
    try std.testing.expectEqual(@as(u8, 29), TimeKit.daysInMonth(2020, 2));
}

test "TimeKit Date struct" {
    const d = TimeKit.Date{ .year = 2021, .month = 6, .day = 15, .hour = 8, .minute = 30, .second = 0 };
    try std.testing.expectEqual(@as(i32, 2021), d.year);
    try std.testing.expectEqual(@as(u8, 6), d.month);
    try std.testing.expectEqual(@as(u8, 15), d.day);
}
