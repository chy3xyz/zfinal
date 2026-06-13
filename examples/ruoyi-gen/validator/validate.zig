const std = @import("std");

/// Validate email format.
pub fn email(v: []const u8) bool {
    return std.mem.indexOfScalar(u8, v, '@') != null and v.len >= 3;
}

/// Validate Chinese mobile phone number.
pub fn phone(v: []const u8) bool {
    return v.len == 11 and v[0] == '1';
}

/// Value must not be null or empty.
pub fn required(v: ?[]const u8) bool {
    if (v) |val| return val.len > 0;
    return false;
}

/// String length in [min, max].
pub fn length(v: []const u8, min: usize, max: usize) bool {
    return v.len >= min and v.len <= max;
}

/// Minimum string length.
pub fn minLen(v: []const u8, n: usize) bool {
    return v.len >= n;
}

/// Maximum string length.
pub fn maxLen(v: []const u8, n: usize) bool {
    return v.len <= n;
}

/// Integer in [lo, hi].
pub fn range(val: i64, lo: i64, hi: i64) bool {
    return val >= lo and val <= hi;
}

/// String matches regex pattern (compile-time pattern).
pub fn pattern(v: []const u8, regex: []const u8) bool {
    _ = regex;
    return v.len > 0; // stub — full regex requires external lib
}

/// Value is a valid integer string.
pub fn isInt(v: []const u8) bool {
    return std.fmt.parseInt(i64, v, 10) != error.InvalidCharacter;
}
