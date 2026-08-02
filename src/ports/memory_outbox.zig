//! In-process outbox with idempotency keys (L3 smoke / unit tests).
const std = @import("std");
const Outbox = @import("outbox.zig").Outbox;
const Bus = @import("../bus/bus.zig").Bus;
const DrainStats = @import("db_outbox.zig").DrainStats;

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

    fn freeEvent(self: *MemoryOutbox, ev: OutboxEvent) void {
        self.allocator.free(ev.event_type);
        self.allocator.free(ev.payload);
        self.allocator.free(ev.idempotency_key);
    }

    /// Publish all pending events to `bus`; successful rows are removed.
    pub fn drainOnce(self: *MemoryOutbox, bus: Bus) !DrainStats {
        var st: DrainStats = .{};
        var i: usize = 0;
        while (i < self.events.items.len) {
            const ev = self.events.items[i];
            bus.publish(ev.event_type, ev.payload) catch {
                st.failed += 1;
                i += 1;
                continue;
            };
            _ = self.events.orderedRemove(i);
            // Keep seen_keys so re-append with same idempotency_key stays no-op.
            self.freeEvent(ev);
            st.published += 1;
        }
        return st;
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

test "MemoryOutbox drainOnce to MemoryBus" {
    const a = std.testing.allocator;
    const MemoryBus = @import("../bus/memory_bus.zig").MemoryBus;
    var box = MemoryOutbox.init(a);
    defer box.deinit();
    var bus_impl = MemoryBus.init(a);
    defer bus_impl.deinit();
    const mb = try bus_impl.queue.subscribe("order.placed");
    defer {
        mb.deinit();
        a.destroy(mb);
    }
    try box.port().append(a, "order.placed", "{\"n\":1}", "k2");
    const st = try box.drainOnce(bus_impl.port());
    try std.testing.expectEqual(@as(usize, 1), st.published);
    try std.testing.expectEqual(@as(usize, 0), box.len());
    var msg = mb.tryPop() orelse return error.TestUnexpectedResult;
    defer msg.deinit(a);
    try std.testing.expectEqualStrings("{\"n\":1}", msg.data);
}
