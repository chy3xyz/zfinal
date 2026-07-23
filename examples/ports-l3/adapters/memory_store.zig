//! Process-local store adapter (L0–L2 smoke).
const std = @import("std");
const ports = @import("../ports/store.zig");

pub const MemoryStore = struct {
    map: std.StringHashMapUnmanaged([]u8) = .{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MemoryStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn port(self: *MemoryStore) ports.Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ── ai-edit-zone: adapter impl ───────────────────────────────
    fn putImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8) anyerror!void {
        _ = allocator;
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        const gop = try self.map.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        } else {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, value);
    }
    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        const v = self.map.get(key) orelse return null;
        return try allocator.dupe(u8, v);
    }
    // ── end ai-edit-zone ─────────────────────────────────────────

    const vtable = ports.Store.VTable{ .put = putImpl, .get = getImpl };
};
