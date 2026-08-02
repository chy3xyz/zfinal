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

    /// Forward subscribe (consume half). Prefer `subscribeGroup` for multi-instance workers.
    pub fn subscribe(
        self: *NatsBus,
        subject: []const u8,
        callback: *const fn (QueueNatsClient.Message) void,
    ) !u64 {
        return try self.client.subscribe(subject, callback);
    }

    pub fn subscribeGroup(
        self: *NatsBus,
        subject: []const u8,
        queue_group: []const u8,
        callback: *const fn (QueueNatsClient.Message) void,
    ) !u64 {
        return try self.client.subscribeGroup(subject, queue_group, callback);
    }

    pub fn poll(self: *NatsBus) !usize {
        return try self.client.poll();
    }
};

test "NatsBus port wires to offline client" {
    var client = QueueNatsClient.initOffline(std.testing.allocator);
    defer client.deinit();
    var bus_impl = NatsBus.init(&client);
    const bus = bus_impl.port();
    // Offline client has no TCP — publish must fail fast, proving the adapter is wired.
    try std.testing.expectError(error.NotConnected, bus.publish("t", "p"));
}

test "NatsBus subscribe offline fails fast" {
    var client = QueueNatsClient.initOffline(std.testing.allocator);
    defer client.deinit();
    var bus_impl = NatsBus.init(&client);
    try std.testing.expectError(error.NotConnected, bus_impl.subscribe("t", struct {
        fn cb(_: QueueNatsClient.Message) void {}
    }.cb));
}

var g_nats_bus_hits: std.atomic.Value(usize) = .init(0);

test "NatsBus live publish and subscribe soak" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const env = if (std.c.getenv("NATS_URL")) |p| std.mem.span(p) else null;
    if (env == null or env.?.len == 0) return error.SkipZigTest;

    const a = std.testing.allocator;
    var client = try QueueNatsClient.connectWithIo(a, std.testing.io, env.?);
    defer client.deinit();
    var bus_impl = NatsBus.init(&client);

    g_nats_bus_hits.store(0, .monotonic);
    const sid = try bus_impl.subscribe("zfinal.test.nats_bus.soak", struct {
        fn cb(msg: QueueNatsClient.Message) void {
            if (std.mem.eql(u8, msg.payload, "bus-soak")) {
                _ = g_nats_bus_hits.fetchAdd(1, .monotonic);
            }
        }
    }.cb);
    defer client.unsubscribe(sid) catch {};

    try bus_impl.port().publish("zfinal.test.nats_bus.soak", "bus-soak");
    try client.flush();

    var waited: usize = 0;
    while (g_nats_bus_hits.load(.monotonic) == 0 and waited < 40) : (waited += 1) {
        _ = try bus_impl.poll();
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(25), .real) catch {};
    }
    try std.testing.expect(g_nats_bus_hits.load(.monotonic) >= 1);
}

