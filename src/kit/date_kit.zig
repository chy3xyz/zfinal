const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// 日期工具类
pub const DateKit = struct {
    /// 日期结构
    pub const Date = struct {
        year: i32,
        month: u8,
        day: u8,
        hour: u8 = 0,
        minute: u8 = 0,
        second: u8 = 0,

        /// 格式化为字符串
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

    /// 获取当前日期
    pub fn now() Date {
        const timestamp = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();
        return fromTimestamp(timestamp);
    }

    /// 从时间戳创建日期
    pub fn fromTimestamp(timestamp: i64) Date {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return Date{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hour = day_seconds.getHoursIntoDay(),
            .minute = day_seconds.getMinutesIntoHour(),
            .second = day_seconds.getSecondsIntoMinute(),
        };
    }

    /// 判断是否是闰年
    pub fn isLeapYear(year: i32) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
    }

    /// 获取月份天数
    pub fn daysInMonth(year: i32, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) 29 else 28,
            else => 0,
        };
    }
};

test "DateKit isLeapYear" {
    try std.testing.expect(DateKit.isLeapYear(2020));
    try std.testing.expect(!DateKit.isLeapYear(2021));
    try std.testing.expect(DateKit.isLeapYear(2000));
    try std.testing.expect(!DateKit.isLeapYear(1900));
}

test "DateKit daysInMonth" {
    try std.testing.expectEqual(@as(u8, 31), DateKit.daysInMonth(2021, 1));
    try std.testing.expectEqual(@as(u8, 28), DateKit.daysInMonth(2021, 2));
    try std.testing.expectEqual(@as(u8, 29), DateKit.daysInMonth(2020, 2));
}
