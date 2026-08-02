//! Process-local cache (L0–L1). Not a multi-instance session store.
const std = @import("std");
const Cache = @import("cache.zig").Cache;

pub const MemoryCache = struct {
    map: std.StringHashMapUnmanaged([]u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryCache) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn port(self: *MemoryCache) Cache {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
        const v = self.map.get(key) orelse return null;
        return try allocator.dupe(u8, v);
    }
    fn setImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_s: u64) anyerror!void {
        _ = ttl_s;
        _ = allocator;
        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
        const gop = try self.map.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        } else {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, value);
    }

    const vtable = Cache.VTable{ .get = getImpl, .set = setImpl };
};

test "MemoryCache set get" {
    const a = std.testing.allocator;
    var c = MemoryCache.init(a);
    defer c.deinit();
    const p = c.port();
    try p.set(a, "k", "v", 60);
    const got = try p.get(a, "k");
    defer if (got) |g| a.free(g);
    try std.testing.expectEqualStrings("v", got.?);
}
