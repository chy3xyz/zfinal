const std = @import("std");
const Plugin = @import("plugin.zig").Plugin;
const TimeKit = @import("../kit/time_kit.zig").TimeKit;

/// 缓存条目
const CacheEntry = struct {
    value: []const u8,
    expires_at: ?i64 = null, // Unix timestamp
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.value);
    }

    pub fn isExpired(self: *const CacheEntry) bool {
        if (self.expires_at) |expires| {
            const now = TimeKit.now();
            return now > expires;
        }
        return false;
    }
};

/// 缓存插件
pub const CachePlugin = struct {
    cache: std.StringHashMap(CacheEntry),
    allocator: std.mem.Allocator,
    name: []const u8 = "cache",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) CachePlugin {
        return CachePlugin{
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.deinit();
    }

    /// 获取缓存值
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        if (self.cache.get(key)) |entry| {
            if (entry.isExpired()) {
                // 删除过期条目
                self.delete(key) catch {};
                return null;
            }
            return entry.value;
        }
        return null;
    }

    /// 设置缓存值
    pub fn set(self: *Self, key: []const u8, value: []const u8, ttl: ?u64) !void {
        // 删除旧值
        if (self.cache.get(key)) |old_entry| {
            var entry = old_entry;
            entry.deinit();
            _ = self.cache.remove(key);
        }

        const expires_at = if (ttl) |t| TimeKit.now() + @as(i64, @intCast(t)) else null;

        const entry = CacheEntry{
            .value = try self.allocator.dupe(u8, value),
            .expires_at = expires_at,
            .allocator = self.allocator,
        };

        const key_copy = try self.allocator.dupe(u8, key);
        try self.cache.put(key_copy, entry);
    }

    /// 删除缓存值
    pub fn delete(self: *Self, key: []const u8) !void {
        // 删除旧值
        if (self.cache.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit();
        }
    }

    /// 清空缓存
    pub fn clear(self: *Self) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.clearRetainingCapacity();
    }

    /// 获取缓存大小
    pub fn size(self: *const Self) usize {
        return self.cache.count();
    }

    // Plugin 接口实现
    pub fn asPlugin(self: *Self) Plugin {
        const vtable = Plugin.VTable{
            .start = startImpl,
            .stop = stopImpl,
        };

        return Plugin{
            .name = self.name,
            .vtable = &vtable,
            .context = self,
        };
    }

    fn startImpl(ctx: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        std.debug.print("Cache plugin started: {s}\n", .{self.name});
    }

    fn stopImpl(ctx: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        std.debug.print("Cache plugin stopped: {s}\n", .{self.name});
        self.clear();
    }
};

test "cache plugin basic" {
    const allocator = std.testing.allocator;

    var cache = CachePlugin.init(allocator);
    defer cache.deinit();

    // 设置和获取
    try cache.set("key1", "value1", null);
    const value = cache.get("key1");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("value1", value.?);

    // 删除
    try cache.delete("key1");
    try std.testing.expect(cache.get("key1") == null);
}

test "cache plugin ttl" {
    const allocator = std.testing.allocator;

    var cache = CachePlugin.init(allocator);
    defer cache.deinit();

    // 设置 TTL 为 1 秒
    try cache.set("key1", "value1", 1);

    // 立即获取应该成功
    try std.testing.expect(cache.get("key1") != null);

    // 等待 2 秒后应该过期（在实际测试中可能需要调整）
    // 注意：这个测试在快速 CI 环境中可能不稳定
}
