const std = @import("std");

/// 验证工具类
pub const ValidateKit = struct {
    /// 验证邮箱
    pub fn isEmail(email: []const u8) bool {
        const at_pos = std.mem.indexOf(u8, email, "@") orelse return false;
        const dot_pos = std.mem.lastIndexOf(u8, email, ".") orelse return false;

        return at_pos > 0 and dot_pos > at_pos + 1 and dot_pos < email.len - 1;
    }

    /// 验证手机号（中国）
    pub fn isPhone(phone: []const u8) bool {
        if (phone.len != 11) return false;
        if (phone[0] != '1') return false;

        for (phone) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }

        return true;
    }

    /// 验证身份证号（中国）
    pub fn isIdCard(id: []const u8) bool {
        if (id.len != 18) return false;

        for (id[0..17]) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }

        const last = id[17];
        return std.ascii.isDigit(last) or last == 'X' or last == 'x';
    }

    /// 验证 IP 地址
    pub fn isIpAddress(ip: []const u8) bool {
        var parts = std.mem.splitScalar(u8, ip, '.');
        var count: usize = 0;

        while (parts.next()) |part| {
            count += 1;
            if (count > 4) return false;

            const num = std.fmt.parseInt(u8, part, 10) catch return false;
            if (num > 255) return false;
        }

        return count == 4;
    }

    /// 验证 URL
    pub fn isUrl(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://") or
            std.mem.startsWith(u8, url, "ftp://");
    }

    /// 验证密码强度
    pub fn isStrongPassword(password: []const u8) bool {
        if (password.len < 8) return false;

        var has_upper = false;
        var has_lower = false;
        var has_digit = false;
        var has_special = false;

        for (password) |c| {
            if (std.ascii.isUpper(c)) has_upper = true;
            if (std.ascii.isLower(c)) has_lower = true;
            if (std.ascii.isDigit(c)) has_digit = true;
            if (!std.ascii.isAlphanumeric(c)) has_special = true;
        }

        return has_upper and has_lower and has_digit and has_special;
    }

    /// 验证长度范围
    pub fn isLengthInRange(str: []const u8, min_len: usize, max_len: usize) bool {
        return str.len >= min_len and str.len <= max_len;
    }

    /// 验证数字范围
    pub fn isNumberInRange(comptime T: type, value: T, min_val: T, max_val: T) bool {
        return value >= min_val and value <= max_val;
    }
};

test "ValidateKit isEmail" {
    try std.testing.expect(ValidateKit.isEmail("test@example.com"));
    try std.testing.expect(!ValidateKit.isEmail("invalid.email"));
}

test "ValidateKit isPhone" {
    try std.testing.expect(ValidateKit.isPhone("13800138000"));
    try std.testing.expect(!ValidateKit.isPhone("12345"));
}

test "ValidateKit isIpAddress" {
    try std.testing.expect(ValidateKit.isIpAddress("192.168.1.1"));
    try std.testing.expect(!ValidateKit.isIpAddress("256.1.1.1"));
}
