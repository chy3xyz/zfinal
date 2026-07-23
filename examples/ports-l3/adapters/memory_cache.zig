//! Process-local cache (L0–L1). Do not use as sole session store under multi-instance L2.
const std = @import("std");
const ports = @import("../ports/cache.zig");

pub const MemoryCache = struct {
    map: std.StringHashMapUnmanaged([]u8) = .{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MemoryCache) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn port(self: *MemoryCache) ports.Cache {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ── ai-edit-zone: adapter impl ───────────────────────────────
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
    // ── end ai-edit-zone ─────────────────────────────────────────

    const vtable = ports.Cache.VTable{ .get = getImpl, .set = setImpl };
};
