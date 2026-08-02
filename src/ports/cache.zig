//! Cache port (L2+). Swap memory ↔ Redis without touching services.
const std = @import("std");

pub const Cache = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8,
        set: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_s: u64) anyerror!void,
    };

    pub fn get(self: Cache, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return self.vtable.get(self.ptr, allocator, key);
    }

    pub fn set(self: Cache, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_s: u64) !void {
        return self.vtable.set(self.ptr, allocator, key, value, ttl_s);
    }
};
