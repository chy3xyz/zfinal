const std = @import("std");
const TimeKit = @import("./time_kit.zig").TimeKit;

/// 缓存工具类（简单的内存缓存）
pub const CacheKit = struct {
    const CacheEntry = struct {
        value: []const u8,
        expires_at: i64,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *CacheEntry) void {
            self.allocator.free(self.value);
        }

        pub fn isExpired(self: *const CacheEntry) bool {
            return TimeKit.now() > self.expires_at;
        }
    };

    cache: std.StringHashMap(CacheEntry),
    allocator: std.mem.Allocator,
    default_ttl: i64 = 300, // 5 分钟

    pub fn init(allocator: std.mem.Allocator) CacheKit {
        return CacheKit{
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CacheKit) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.deinit();
    }

    /// 设置缓存
    pub fn set(self: *CacheKit, key: []const u8, value: []const u8, ttl: ?i64) !void {
        // 删除旧值
        if (self.cache.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit();
        }

        const expires_at = TimeKit.now() + (ttl orelse self.default_ttl);

        const entry = CacheEntry{
            .value = try self.allocator.dupe(u8, value),
            .expires_at = expires_at,
            .allocator = self.allocator,
        };

        const key_copy = try self.allocator.dupe(u8, key);
        try self.cache.put(key_copy, entry);
    }

    /// 获取缓存
    pub fn get(self: *CacheKit, key: []const u8) ?[]const u8 {
        if (self.cache.get(key)) |entry| {
            if (entry.isExpired()) {
                self.delete(key) catch {};
                return null;
            }
            return entry.value;
        }
        return null;
    }

    /// 删除缓存
    pub fn delete(self: *CacheKit, key: []const u8) !void {
        if (self.cache.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit();
        }
    }

    /// 清空缓存
    pub fn clear(self: *CacheKit) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.clearRetainingCapacity();
    }

    /// 清理过期缓存
    pub fn cleanup(self: *CacheKit) !void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                // 删除过期条目
                if (self.cache.fetchRemove(entry.key_ptr.*)) |kv| {
                    self.allocator.free(kv.key);
                    var val = kv.value;
                    val.deinit();
                }
            }
        }
    }
};

test "CacheKit basic" {
    const allocator = std.testing.allocator;

    var cache = CacheKit.init(allocator);
    defer cache.deinit();

    try cache.set("key1", "value1", 10);

    const value = cache.get("key1");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("value1", value.?);

    try cache.delete("key1");
    try std.testing.expect(cache.get("key1") == null);
}
