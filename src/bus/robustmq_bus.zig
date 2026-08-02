//! RobustMQ / Kafka bus adapter — L3 publish path (`QueueRobustMQClient`).
//! Owns nothing: borrow a `QueueRobustMQClient` (online or offline).
//! Consume: use `KafkaConsumer` (subscribe + poll) alongside this publisher —
//! see test below and `doc/robustmq.md`.

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const QueueRobustMQClient = @import("../plugin/robustmq.zig").QueueRobustMQClient;
const KafkaConsumer = @import("../plugin/robustmq.zig").KafkaConsumer;

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

test "RobustMQBus publish + KafkaConsumer subscribe offline pairing" {
    // Documents the L3 split: Bus for publish, KafkaConsumer for consume/poll.
    var client = QueueRobustMQClient.connectOffline(std.testing.allocator);
    defer client.deinit();
    var bus_impl = RobustMQBus.init(&client);
    try bus_impl.port().publish("orders.created", "{\"id\":2}");

    var consumer = KafkaConsumer.init(std.testing.allocator, .{});
    defer consumer.deinit();
    try consumer.subscribe("orders.created", struct {
        fn handler(_: @import("../plugin/robustmq.zig").KafkaMessage) void {}
    }.handler);
    try std.testing.expectEqual(@as(usize, 1), consumer.subscriptions.count());
    // Offline poll is a no-op / soft failure path — wiring must not panic.
    _ = consumer.poll() catch {};
}
