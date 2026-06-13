const std = @import("std");

/// DateKit merged into TimeKit. Re-exported for backward compatibility.
pub const DateKit = struct {
    pub const Date = @import("time_kit.zig").TimeKit.Date;

    pub fn now() Date {
        return @import("time_kit.zig").TimeKit.nowDate();
    }
    pub fn fromTimestamp(timestamp: i64) Date {
        return @import("time_kit.zig").TimeKit.fromTimestamp(timestamp);
    }
    pub fn isLeapYear(year: i32) bool {
        return @import("time_kit.zig").TimeKit.isLeapYear(year);
    }
    pub fn daysInMonth(year: i32, month: u8) u8 {
        return @import("time_kit.zig").TimeKit.daysInMonth(year, month);
    }
};
