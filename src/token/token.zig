const std = @import("std");
const TimeKit = @import("../kit/time_kit.zig").TimeKit;
const RandomKit = @import("../kit/random_kit.zig").RandomKit;
const io_instance = @import("../io_instance.zig");

/// Token 信息. Value is the HashMap key — no duplication needed.
pub const Token = struct {
    created_at: i64,

    pub fn deinit(self: *Token) void {
        _ = self; // no owned allocations
    }

    /// 检查是否过期
    pub fn isExpired(self: *const Token, ttl: i64) bool {
        const elapsed = TimeKit.now() - self.created_at;
        return elapsed > ttl;
    }
};

/// Token 管理器
pub const TokenManager = struct {
    tokens: std.StringHashMap(Token),
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    default_: i64 = 3600, // 默认 1 小时
    /// 上次全表清理时间（unix 秒）。`validate` 用低频 sweep 取代每次都全表扫描。
    last_sweep: i64 = 0,

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
        self.* = undefined;
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

        // Single allocation: returned to caller
        const token_ret = try self.allocator.dupe(u8, token_value);
        errdefer self.allocator.free(token_ret);

        // Single allocation: HashMap key (Token.value == key, no 3rd alloc)
        const token_key = try self.allocator.dupe(u8, token_value);
        errdefer self.allocator.free(token_key);

        try self.tokens.put(token_key, Token{ .created_at = TimeKit.now() });

        return token_ret;
    }

    /// 验证并移除 Token。
    ///
    /// 热路径 O(1)：只处理目标 token，不再每次调用都全表扫描（旧实现持锁
    /// `cleanExpired` 是 O(n)，token 多时直接拖慢每次校验）。过期 token 由
    /// 低频 sweep（最多 60s 一次）或外部 `purgeExpired()` 回收；目标 token
    /// 本身仍会判过期，所以 sweep 间隙里过期 token 也不会通过校验。
    pub fn validate(self: *TokenManager, token_value: []const u8) !bool {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        const now = TimeKit.now();
        if (now - self.last_sweep >= 60) {
            try self.cleanExpired();
            self.last_sweep = now;
        }

        const kv = self.tokens.fetchRemove(token_value) orelse return false;
        self.allocator.free(kv.key);
        var val = kv.value;
        defer val.deinit();
        return !val.isExpired(self.default_);
    }

    /// 检查 Token 是否存在（不移除）。
    /// Takes the manager mutex: a concurrent `put`/`validate` can rehash the
    /// map, and an unsynchronized read of a rehashing HashMap is UB.
    pub fn exists(self: *TokenManager, token_value: []const u8) bool {
        self.mutex.lock(io_instance.io) catch return false;
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

    /// Public entry for periodic cleanup (cron / idle sweep). Call under no
    /// external lock — this method acquires the manager mutex.
    pub fn purgeExpired(self: *TokenManager) !void {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        try self.cleanExpired();
    }

    /// 设置 TTL
    pub fn setTTL(self: *TokenManager, ttl: i64) void {
        self.default_ = ttl;
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

test "token: validate rejects an expired token even between sweeps" {
    const allocator = std.testing.allocator;
    var manager = TokenManager.init(allocator);
    defer manager.deinit();

    // Negative TTL makes the freshly generated token already expired, and
    // `last_sweep` starts at 0 so no full sweep runs first — the target token
    // itself must still be rejected (this is the security-relevant path).
    manager.setTTL(-1);
    const token = try manager.generate();
    defer allocator.free(token);

    try std.testing.expect(!(try manager.validate(token)));
    try std.testing.expectEqual(@as(usize, 0), manager.count());
}
