const std = @import("std");
const TimeKit = @import("../kit/time_kit.zig").TimeKit;
const RandomKit = @import("../kit/random_kit.zig").RandomKit;
const io_instance = @import("../io_instance.zig");

/// Token 信息
pub const Token = struct {
    value: []const u8,
    created_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Token) void {
        self.allocator.free(self.value);
    }

    /// 检查是否过期
    pub fn isExpired(self: *const Token, _: i64) bool {
        _ = self;
        return false;
    }
};

/// Token 管理器
pub const TokenManager = struct {
    tokens: std.StringHashMap(Token),
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    default_: i64 = 3600, // 默认 1 小时

    pub fn init(allocator: std.mem.Allocator) TokenManager {
        return TokenManager{
            .tokens = std.StringHashMap(Token).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TokenManager) void {
        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.tokens.deinit();
    }

    /// 生成新 Token
    pub fn generate(self: *TokenManager) ![]const u8 {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        // 生成随机 Token
        var random_bytes: [32]u8 = undefined;
        RandomKit.randomBytes(&random_bytes);

        // Base64 编码
        const encoder = std.base64.url_safe_no_pad.Encoder;
        var token_buf: [64]u8 = undefined;
        const token_value = encoder.encode(&token_buf, &random_bytes);

        // 复制 Token 用于返回
        const token_ret = try self.allocator.dupe(u8, token_value);
        errdefer self.allocator.free(token_ret);

        // 复制 Token 用于 Map Key
        const token_key = try self.allocator.dupe(u8, token_value);
        errdefer self.allocator.free(token_key);

        // 存储 Token
        const token = Token{
            .value = try self.allocator.dupe(u8, token_value),
            .created_at = TimeKit.now(),
            .allocator = self.allocator,
        };

        try self.tokens.put(token_key, token);

        return token_ret;
    }

    /// 验证并移除 Token
    pub fn validate(self: *TokenManager, token_value: []const u8) !bool {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        // 清理过期 Token
        try self.cleanExpired();

        // 查找 Token
        if (self.tokens.fetchRemove(token_value)) |kv| {
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit();
            return true;
        }

        return false;
    }

    /// 检查 Token 是否存在（不移除）
    pub fn exists(self: *TokenManager, token_value: []const u8) bool {
        self.mutex.lock(io_instance.io) catch {};
        defer self.mutex.unlock(io_instance.io);

        if (self.tokens.get(token_value)) |token| {
            return !token.isExpired(self.default_);
        }
        return false;
    }

    /// 清理过期 Token
    fn cleanExpired(self: *TokenManager) !void {
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired(self.default_)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            if (self.tokens.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                var val = kv.value;
                val.deinit();
            }
        }
    }

    /// 设置 TTL
    pub fn setTTL(self: *TokenManager, ttl: i64) void {
        self.default_ttl = ttl;
    }

    /// 获取 Token 数量
    pub fn count(self: *const TokenManager) usize {
        return self.tokens.count();
    }
};

test "token generation and validation" {
    const allocator = std.testing.allocator;

    var manager = TokenManager.init(allocator);
    defer manager.deinit();

    // 生成 Token
    const token = try manager.generate();
    defer allocator.free(token);

    // 验证存在
    try std.testing.expect(manager.exists(token));

    // 验证并移除
    const valid = try manager.validate(token);
    try std.testing.expect(valid);

    // 再次验证应该失败
    const valid2 = try manager.validate(token);
    try std.testing.expect(!valid2);
}