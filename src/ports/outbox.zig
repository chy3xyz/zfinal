//! Outbox port (L3). Persist delivery intent in the same unit of work as domain writes.
const std = @import("std");

pub const Outbox = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        append: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            event_type: []const u8,
            payload: []const u8,
            idempotency_key: []const u8,
        ) anyerror!void,
    };

    pub fn append(
        self: Outbox,
        allocator: std.mem.Allocator,
        event_type: []const u8,
        payload: []const u8,
        idempotency_key: []const u8,
    ) !void {
        return self.vtable.append(self.ptr, allocator, event_type, payload, idempotency_key);
    }
};
