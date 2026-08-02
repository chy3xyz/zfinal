//! NATS bus adapter — L3 multi-instance (queue groups for consume).
//! Owns nothing: borrow a connected `QueueNatsClient`.

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const QueueNatsClient = @import("../plugin/queue_nats.zig").QueueNatsClient;

pub const NatsBus = struct {
    client: *QueueNatsClient,

    pub fn init(client: *QueueNatsClient) NatsBus {
        return .{ .client = client };
    }

    pub fn port(self: *NatsBus) Bus {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn publishImpl(ptr: *anyopaque, topic: []const u8, payload: []const u8) anyerror!void {
        const self: *NatsBus = @ptrCast(@alignCast(ptr));
        try self.client.publish(topic, payload);
    }

    const vtable = Bus.VTable{ .publish = publishImpl };
};

test "NatsBus port wires to offline client" {
    var client = QueueNatsClient.initOffline(std.testing.allocator);
    defer client.deinit();
    var bus_impl = NatsBus.init(&client);
    const bus = bus_impl.port();
    // Offline client has no TCP — publish must fail fast, proving the adapter is wired.
    try std.testing.expectError(error.NotConnected, bus.publish("t", "p"));
}
