const std = @import("std");

/// Token 信息
pub const Token = struct {
    value: []const u8,
    created_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Token) void {
        self.allocator.free(self.value);
    }

    /// 检查是否过期
    pub fn isExpired(self: *const Token, ttl: i64) bool {
        const now = std.time.timestamp();
        return (now - self.created_at) > ttl;
    }
};

/// Token 管理器
pub const TokenManager = struct {
    tokens: std.StringHashMap(Token),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    default_ttl: i64 = 3600, // 默认 1 小时

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
        self.mutex.lock();
        defer self.mutex.unlock();

        // 生成随机 Token
        var random_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

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
            .created_at = std.time.timestamp(),
            .allocator = self.allocator,
        };

        try self.tokens.put(token_key, token);

        return token_ret;
    }

    /// 验证并移除 Token
    pub fn validate(self: *TokenManager, token_value: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tokens.get(token_value)) |token| {
            return !token.isExpired(self.default_ttl);
        }
        return false;
    }

    /// 清理过期 Token
    fn cleanExpired(self: *TokenManager) !void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired(self.default_ttl)) {
                try to_remove.append(entry.key_ptr.*);
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
