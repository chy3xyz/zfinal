const std = @import("std");
const RandomKit = @import("../kit/random_kit.zig").RandomKit;

/// 验证码类型
pub const CaptchaType = enum {
    numeric, // 纯数字
    alpha, // 纯字母
    alphanumeric, // 字母+数字
    math, // 数学运算
};

/// 验证码
pub const Captcha = struct {
    code: []const u8,
    answer: []const u8,
    created_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Captcha) void {
        self.allocator.free(self.code);
        self.allocator.free(self.answer);
    }

    /// 检查是否过期
    pub fn isExpired(self: *const Captcha, ttl: i64) bool {
        const now = std.time.timestamp();
        return (now - self.created_at) > ttl;
    }
};

/// 验证码管理器
pub const CaptchaManager = struct {
    captchas: std.StringHashMap(Captcha),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    default_ttl: i64 = 300, // 5 分钟
    default_length: usize = 4,

    pub fn init(allocator: std.mem.Allocator) CaptchaManager {
        return CaptchaManager{
            .captchas = std.StringHashMap(Captcha).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CaptchaManager) void {
        var it = self.captchas.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.captchas.deinit();
    }

    /// 生成验证码
    pub fn generate(self: *CaptchaManager, captcha_type: CaptchaType, session_id: []const u8) !Captcha {
        self.mutex.lock();
        defer self.mutex.unlock();

        const code = try self.generateCode(captcha_type);
        errdefer self.allocator.free(code);

        const answer = try self.generateAnswer(captcha_type, code);
        errdefer self.allocator.free(answer);

        const captcha = Captcha{
            .code = code,
            .answer = answer,
            .created_at = std.time.timestamp(),
            .allocator = self.allocator,
        };

        // 删除旧的验证码
        if (self.captchas.fetchRemove(session_id)) |kv| {
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit();
        }

        const session_copy = try self.allocator.dupe(u8, session_id);
        try self.captchas.put(session_copy, captcha);

        return captcha;
    }

    /// 验证验证码
    pub fn validate(self: *CaptchaManager, session_id: []const u8, user_input: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 清理过期验证码
        try self.cleanExpired();

        if (self.captchas.fetchRemove(session_id)) |kv| {
            defer self.allocator.free(kv.key);
            var val = kv.value;
            defer val.deinit();

            if (val.isExpired(self.default_ttl)) {
                return false;
            }

            // 不区分大小写比较
            const lower_input = try std.ascii.allocLowerString(self.allocator, user_input);
            defer self.allocator.free(lower_input);

            const lower_answer = try std.ascii.allocLowerString(self.allocator, val.answer);
            defer self.allocator.free(lower_answer);

            return std.mem.eql(u8, lower_input, lower_answer);
        }

        return false;
    }

    /// 生成验证码字符串
    fn generateCode(self: *CaptchaManager, captcha_type: CaptchaType) ![]const u8 {
        return switch (captcha_type) {
            .numeric => try self.generateNumeric(),
            .alpha => try self.generateAlpha(),
            .alphanumeric => try self.generateAlphanumeric(),
            .math => try self.generateMath(),
        };
    }

    /// 生成答案
    fn generateAnswer(self: *CaptchaManager, captcha_type: CaptchaType, code: []const u8) ![]const u8 {
        return switch (captcha_type) {
            .math => try self.calculateMath(code),
            else => try self.allocator.dupe(u8, code),
        };
    }

    /// 生成纯数字验证码
    fn generateNumeric(self: *CaptchaManager) ![]const u8 {
        const chars = "0123456789";
        var result = try self.allocator.alloc(u8, self.default_length);

        for (0..self.default_length) |i| {
            const idx = RandomKit.randomInt(usize, 0, chars.len - 1);
            result[i] = chars[idx];
        }

        return result;
    }

    /// 生成纯字母验证码
    fn generateAlpha(self: *CaptchaManager) ![]const u8 {
        const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz"; // 去除易混淆字符
        var result = try self.allocator.alloc(u8, self.default_length);

        for (0..self.default_length) |i| {
            const idx = RandomKit.randomInt(usize, 0, chars.len - 1);
            result[i] = chars[idx];
        }

        return result;
    }

    /// 生成字母数字验证码
    fn generateAlphanumeric(self: *CaptchaManager) ![]const u8 {
        const chars = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz"; // 去除易混淆字符
        var result = try self.allocator.alloc(u8, self.default_length);

        for (0..self.default_length) |i| {
            const idx = RandomKit.randomInt(usize, 0, chars.len - 1);
            result[i] = chars[idx];
        }

        return result;
    }

    /// 生成数学运算验证码
    fn generateMath(self: *CaptchaManager) ![]const u8 {
        const a = RandomKit.randomInt(i32, 1, 20);
        const b = RandomKit.randomInt(i32, 1, 20);
        const op = RandomKit.randomInt(usize, 0, 1); // 0: +, 1: -

        if (op == 0) {
            return try std.fmt.allocPrint(self.allocator, "{d} + {d} = ?", .{ a, b });
        } else {
            // 确保结果为正数
            const larger = @max(a, b);
            const smaller = @min(a, b);
            return try std.fmt.allocPrint(self.allocator, "{d} - {d} = ?", .{ larger, smaller });
        }
    }

    /// 计算数学运算结果
    fn calculateMath(self: *CaptchaManager, code: []const u8) ![]const u8 {
        // 解析 "a + b = ?" 或 "a - b = ?"
        var parts = std.mem.splitScalar(u8, code, ' ');

        const a_str = parts.next() orelse return error.InvalidMath;
        const op = parts.next() orelse return error.InvalidMath;
        const b_str = parts.next() orelse return error.InvalidMath;

        const a = try std.fmt.parseInt(i32, a_str, 10);
        const b = try std.fmt.parseInt(i32, b_str, 10);

        const result = if (std.mem.eql(u8, op, "+"))
            a + b
        else if (std.mem.eql(u8, op, "-"))
            a - b
        else
            return error.InvalidOperator;

        return try std.fmt.allocPrint(self.allocator, "{d}", .{result});
    }

    /// 清理过期验证码
    fn cleanExpired(self: *CaptchaManager) !void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.captchas.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired(self.default_ttl)) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            if (self.captchas.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                var val = kv.value;
                val.deinit();
            }
        }
    }

    /// 设置 TTL
    pub fn setTTL(self: *CaptchaManager, ttl: i64) void {
        self.default_ttl = ttl;
    }

    /// 设置验证码长度
    pub fn setLength(self: *CaptchaManager, length: usize) void {
        self.default_length = length;
    }
};

test "captcha numeric" {
    const allocator = std.testing.allocator;

    var manager = CaptchaManager.init(allocator);
    defer manager.deinit();

    const captcha = try manager.generate(.numeric, "session1");
    try std.testing.expectEqual(@as(usize, 4), captcha.code.len);

    // 验证所有字符都是数字
    for (captcha.code) |c| {
        try std.testing.expect(std.ascii.isDigit(c));
    }
}

test "captcha validation" {
    const allocator = std.testing.allocator;

    var manager = CaptchaManager.init(allocator);
    defer manager.deinit();

    const captcha = try manager.generate(.numeric, "session1");

    // 正确答案
    const valid = try manager.validate("session1", captcha.answer);
    try std.testing.expect(valid);

    // 验证码已被消费，再次验证应该失败
    const valid2 = try manager.validate("session1", captcha.answer);
    try std.testing.expect(!valid2);
}
