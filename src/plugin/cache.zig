const std = @import("std");
const Plugin = @import("plugin.zig").Plugin;
const TimeKit = @import("../kit/time_kit.zig").TimeKit;
const RedisClient = @import("redis.zig").RedisClient;

/// Cache backend type
pub const CacheBackend = enum {
    memory,
    redis,
};

/// Cache configuration
pub const CacheConfig = struct {
    backend: CacheBackend = .memory,
    // Redis settings
    redis_host: []const u8 = "127.0.0.1",
    redis_port: u16 = 6379,
    redis_default_ttl: u64 = 300, // 5 minutes
    // Memory settings
    memory_max_size: usize = 10000, // Max number of entries
    memory_cleanup_interval: u64 = 60, // Cleanup interval in seconds
};

/// Memory cache entry
const CacheEntry = struct {
    value: []const u8,
    expires_at: ?i64 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.value);
    }

    pub fn isExpired(self: *const CacheEntry) bool {
        if (self.expires_at) |expires| {
            return TimeKit.now() > expires;
        }
        return false;
    }
};

/// Enhanced cache plugin with multiple backend support
pub const CachePlugin = struct {
    backend: CacheBackend,
    allocator: std.mem.Allocator,
    name: []const u8 = "cache",

    // Memory backend
    memory_cache: ?std.StringHashMap(CacheEntry) = null,

    // Redis backend
    redis_client: ?RedisClient = null,

    // Config
    config: CacheConfig,

    const Self = @This();

    /// Initialize with default memory backend
    pub fn init(allocator: std.mem.Allocator) CachePlugin {
        return CachePlugin{
            .backend = .memory,
            .allocator = allocator,
            .memory_cache = std.StringHashMap(CacheEntry).init(allocator),
            .config = .{},
        };
    }

    /// Initialize with custom configuration
    pub fn initWithConfig(allocator: std.mem.Allocator, config: CacheConfig) !CachePlugin {
        var plugin = CachePlugin{
            .backend = config.backend,
            .allocator = allocator,
            .config = config,
        };

        switch (config.backend) {
            .memory => {
                plugin.memory_cache = std.StringHashMap(CacheEntry).init(allocator);
            },
            .redis => {
                var client = try RedisClient.init(allocator, config.redis_host, config.redis_port);
                try client.connect();
                plugin.redis_client = client;
            },
        }

        return plugin;
    }

    pub fn deinit(self: *Self) void {
        if (self.memory_cache) |*cache| {
            var it = cache.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit();
            }
            cache.deinit();
        }

        if (self.redis_client) |*client| {
            client.deinit();
        }
    }

    /// Get cached value
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        switch (self.backend) {
            .memory => {
                if (self.memory_cache) |*cache| {
                    if (cache.get(key)) |entry| {
                        if (entry.isExpired()) {
                            self.delete(key) catch {};
                            return null;
                        }
                        return entry.value;
                    }
                }
                return null;
            },
            .redis => {
                if (self.redis_client) |*client| {
                    return client.get(key) catch |err| {
                        std.debug.print("Redis get error: {}\n", .{err});
                        return null;
                    };
                }
                return null;
            },
        }
    }

    /// Set cache value
    pub fn set(self: *Self, key: []const u8, value: []const u8, ttl: ?u64) !void {
        switch (self.backend) {
            .memory => {
                if (self.memory_cache) |*cache| {
                    // Remove old value
                    if (cache.fetchRemove(key)) |kv| {
                        self.allocator.free(kv.key);
                        var val = kv.value;
                        val.deinit();
                    }

                    const expires_at = if (ttl) |t| TimeKit.now() + @as(i64, @intCast(t)) else null;

                    const entry = CacheEntry{
                        .value = try self.allocator.dupe(u8, value),
                        .expires_at = expires_at,
                        .allocator = self.allocator,
                    };

                    const key_copy = try self.allocator.dupe(u8, key);
                    try cache.put(key_copy, entry);
                }
            },
            .redis => {
                if (self.redis_client) |*client| {
                    const seconds = ttl orelse self.config.redis_default_ttl;
                    try client.setEx(key, value, seconds);
                }
            },
        }
    }

    /// Delete cache value
    pub fn delete(self: *Self, key: []const u8) !void {
        switch (self.backend) {
            .memory => {
                if (self.memory_cache) |*cache| {
                    if (cache.fetchRemove(key)) |kv| {
                        self.allocator.free(kv.key);
                        var val = kv.value;
                        val.deinit();
                    }
                }
            },
            .redis => {
                if (self.redis_client) |*client| {
                    try client.del(key);
                }
            },
        }
    }

    /// Clear all cache
    pub fn clear(self: *Self) !void {
        switch (self.backend) {
            .memory => {
                if (self.memory_cache) |*cache| {
                    var it = cache.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit();
                    }
                    cache.clearRetainingCapacity();
                }
            },
            .redis => {
                if (self.redis_client) |*client| {
                    try client.flushDb();
                }
            },
        }
    }

    /// Get cache size (memory only, returns 0 for Redis)
    pub fn size(self: *const Self) usize {
        switch (self.backend) {
            .memory => {
                if (self.memory_cache) |cache| {
                    return cache.count();
                }
                return 0;
            },
            .redis => return 0,
        }
    }

    /// Check if Redis is connected
    pub fn isRedisConnected(self: *Self) bool {
        if (self.redis_client) |*client| {
            return client.ping() catch false;
        }
        return false;
    }

    // Plugin interface implementation
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
        std.debug.print("Cache plugin started: {s} (backend: {s})\n", .{ self.name, @tagName(self.backend) });
    }

    fn stopImpl(ctx: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        std.debug.print("Cache plugin stopped: {s}\n", .{self.name});
        self.clear() catch {};
    }
};

test "cache plugin basic" {
    const allocator = std.testing.allocator;

    var cache = CachePlugin.init(allocator);
    defer cache.deinit();

    // Set and get
    try cache.set("key1", "value1", null);
    const value = cache.get("key1");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("value1", value.?);

    // Delete
    try cache.delete("key1");
    try std.testing.expect(cache.get("key1") == null);
}

test "cache plugin ttl" {
    const allocator = std.testing.allocator;

    var cache = CachePlugin.init(allocator);
    defer cache.deinit();

    // Set TTL to 1 second
    try cache.set("key1", "value1", 1);

    // Should succeed immediately
    try std.testing.expect(cache.get("key1") != null);
}
