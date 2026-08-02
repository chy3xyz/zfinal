//! RobustMQ / Kafka bus adapter — L3 publish path (`QueueRobustMQClient`).
//! Owns nothing: borrow a `QueueRobustMQClient` (online or offline).

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const QueueRobustMQClient = @import("../plugin/robustmq.zig").QueueRobustMQClient;

pub const RobustMQBus = struct {
    client: *QueueRobustMQClient,

    pub fn init(client: *QueueRobustMQClient) RobustMQBus {
        return .{ .client = client };
    }

    pub fn port(self: *RobustMQBus) Bus {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn publishImpl(ptr: *anyopaque, topic: []const u8, payload: []const u8) anyerror!void {
        const self: *RobustMQBus = @ptrCast(@alignCast(ptr));
        try self.client.publish(topic, payload);
    }

    const vtable = Bus.VTable{ .publish = publishImpl };
};

test "RobustMQBus port publishes via offline client" {
    var client = QueueRobustMQClient.connectOffline(std.testing.allocator);
    defer client.deinit();
    var bus_impl = RobustMQBus.init(&client);
    const bus = bus_impl.port();
    // Offline producer accepts local enqueue without a broker.
    try bus.publish("orders.created", "{\"id\":1}");
}
