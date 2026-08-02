//! In-process outbox with idempotency keys (L3 smoke / unit tests).
const std = @import("std");
const Outbox = @import("outbox.zig").Outbox;

pub const OutboxEvent = struct {
    event_type: []u8,
    payload: []u8,
    idempotency_key: []u8,
};

pub const MemoryOutbox = struct {
    events: std.ArrayList(OutboxEvent) = .empty,
    seen_keys: std.StringHashMapUnmanaged(void) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryOutbox {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryOutbox) void {
        for (self.events.items) |ev| {
            self.allocator.free(ev.event_type);
            self.allocator.free(ev.payload);
            self.allocator.free(ev.idempotency_key);
        }
        self.events.deinit(self.allocator);
        var it = self.seen_keys.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.seen_keys.deinit(self.allocator);
    }

    pub fn port(self: *MemoryOutbox) Outbox {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn len(self: *const MemoryOutbox) usize {
        return self.events.items.len;
    }

    fn appendImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        event_type: []const u8,
        payload: []const u8,
        idempotency_key: []const u8,
    ) anyerror!void {
        _ = allocator;
        const self: *MemoryOutbox = @ptrCast(@alignCast(ptr));
        const gop = try self.seen_keys.getOrPut(self.allocator, idempotency_key);
        if (gop.found_existing) return;
        gop.key_ptr.* = try self.allocator.dupe(u8, idempotency_key);
        try self.events.append(self.allocator, .{
            .event_type = try self.allocator.dupe(u8, event_type),
            .payload = try self.allocator.dupe(u8, payload),
            .idempotency_key = try self.allocator.dupe(u8, idempotency_key),
        });
    }

    const vtable = Outbox.VTable{ .append = appendImpl };
};

test "MemoryOutbox idempotent append" {
    const a = std.testing.allocator;
    var box = MemoryOutbox.init(a);
    defer box.deinit();
    const p = box.port();
    try p.append(a, "order.placed", "{}", "k1");
    try p.append(a, "order.placed", "{}", "k1");
    try std.testing.expectEqual(@as(usize, 1), box.len());
}
