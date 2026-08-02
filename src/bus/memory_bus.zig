//! In-process bus via `QueueClient` (L0–L2 / unit tests).

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const QueueClient = @import("../plugin/queue.zig").QueueClient;

pub const MemoryBus = struct {
    queue: QueueClient,

    pub fn init(allocator: std.mem.Allocator) MemoryBus {
        return .{ .queue = QueueClient.init(allocator) };
    }

    pub fn deinit(self: *MemoryBus) void {
        self.queue.deinit();
    }

    pub fn port(self: *MemoryBus) Bus {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Underlying in-process queue (subscribe / mailboxes for tests).
    pub fn queueClient(self: *MemoryBus) *QueueClient {
        return &self.queue;
    }

    fn publishImpl(ptr: *anyopaque, topic: []const u8, payload: []const u8) anyerror!void {
        const self: *MemoryBus = @ptrCast(@alignCast(ptr));
        try self.queue.publish(topic, payload);
    }

    const vtable = Bus.VTable{ .publish = publishImpl };
};

test "MemoryBus publish reaches subscriber mailbox" {
    const allocator = std.testing.allocator;
    var bus_impl = MemoryBus.init(allocator);
    defer bus_impl.deinit();

    const mb = try bus_impl.queue.subscribe("order.placed");
    defer {
        mb.deinit();
        allocator.destroy(mb);
    }

    const bus = bus_impl.port();
    try bus.publish("order.placed", "{\"id\":1}");

    var msg = mb.tryPop() orelse {
        try std.testing.expect(false);
        return;
    };
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("order.placed", msg.subject);
    try std.testing.expectEqualStrings("{\"id\":1}", msg.data);
}
