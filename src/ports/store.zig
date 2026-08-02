//! Read/write key-value store port (L2+).
const std = @import("std");

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8) anyerror!void,
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8,
    };

    pub fn put(self: Store, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        return self.vtable.put(self.ptr, allocator, key, value);
    }

    pub fn get(self: Store, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return self.vtable.get(self.ptr, allocator, key);
    }
};
