//! Queue-shaped NATS façade over zero-dep `nats_client.zig` (NATS wire protocol).
//!
//! Stable sibling of `QueueClient` (memory) and `QueueRobustMQClient` (Kafka/RobustMQ).
//! No `nats.zig` package required.
//!
//! ```zig
//! var q = try zfinal.QueueNatsClient.connect(allocator, "nats://127.0.0.1:4222");
//! defer q.deinit();
//! try q.publish("orders.new", "{\"id\":1}");
//! ```
//!
//! Live tests: set `NATS_URL=127.0.0.1` (host only) or use defaults against a local nats-server.

const std = @import("std");
const builtin = @import("builtin");
const io_instance = @import("../io_instance.zig");
const nats_client = @import("nats_client.zig");

pub const NatsClient = nats_client.NatsClient;
pub const NatsConfig = nats_client.NatsConfig;

/// NATS-backed message queue (publish / subscribe / request-reply).
pub const QueueNatsClient = struct {
    allocator: std.mem.Allocator,
    client: NatsClient,
    /// Owned host string when parsed from `nats://…` URL (freed in deinit).
    owned_host: ?[]const u8 = null,

    pub const Message = NatsClient.Message;

    /// Connect using framework `io_instance.io`.
    /// `url` may be `host`, `host:port`, or `nats://host:port`.
    pub fn connect(allocator: std.mem.Allocator, url: []const u8) !QueueNatsClient {
        return connectWithIo(allocator, io_instance.io, url);
    }

    pub fn connectWithIo(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !QueueNatsClient {
        const host, const port, const owned = try parseNatsUrl(allocator, url);
        var self: QueueNatsClient = .{
            .allocator = allocator,
            .owned_host = if (owned) host else null,
            .client = NatsClient.init(allocator, io, .{
                .url = host,
                .port = port,
                .name = "zfinal-nats",
            }),
        };
        errdefer self.deinit();
        _ = try self.client.connect();
        return self;
    }

    /// Offline shell for unit tests (no TCP). Callers must not publish until `connect*` succeeds.
    pub fn initOffline(allocator: std.mem.Allocator) QueueNatsClient {
        return .{
            .allocator = allocator,
            .client = NatsClient.init(allocator, io_instance.io, .{}),
        };
    }

    pub fn deinit(self: *QueueNatsClient) void {
        self.client.deinit();
        if (self.owned_host) |h| self.allocator.free(h);
        self.owned_host = null;
    }

    pub fn publish(self: *QueueNatsClient, subject: []const u8, data: []const u8) !void {
        try self.client.publish(subject, data);
    }

    pub fn publishReply(self: *QueueNatsClient, subject: []const u8, reply_to: []const u8, data: []const u8) !void {
        try self.client.publishReply(subject, reply_to, data);
    }

    pub fn subscribe(self: *QueueNatsClient, subject: []const u8, callback: *const fn (Message) void) !u64 {
        return try self.client.subscribe(subject, callback);
    }

    pub fn subscribeGroup(self: *QueueNatsClient, subject: []const u8, queue_group: []const u8, callback: *const fn (Message) void) !u64 {
        return try self.client.subscribeGroup(subject, queue_group, callback);
    }

    pub fn unsubscribe(self: *QueueNatsClient, sid: u64) !void {
        try self.client.unsubscribe(sid);
    }

    /// Request/reply; caller owns returned payload. Returns `error.Timeout` on deadline.
    pub fn request(self: *QueueNatsClient, subject: []const u8, data: []const u8, timeout_ms: u64) ![]const u8 {
        return try self.client.request(subject, data, timeout_ms);
    }

    pub fn poll(self: *QueueNatsClient) !usize {
        return try self.client.poll();
    }

    pub fn ping(self: *QueueNatsClient) !void {
        try self.client.ping();
    }

    pub fn flush(self: *QueueNatsClient) !void {
        try self.client.flush();
    }
};

/// Returns `{ host, port, owned }` — if `owned`, caller must free `host`.
fn parseNatsUrl(allocator: std.mem.Allocator, url: []const u8) !struct { []const u8, u16, bool } {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "nats://")) rest = rest["nats://".len..];
    if (std.mem.startsWith(u8, rest, "tcp://")) rest = rest["tcp://".len..];

    // strip path / query
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest = rest[0..i];

    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        const host_part = rest[0..colon];
        const port = try std.fmt.parseInt(u16, rest[colon + 1 ..], 10);
        if (host_part.len == 0) return error.InvalidNatsUrl;
        const host = try allocator.dupe(u8, host_part);
        return .{ host, port, true };
    }
    if (rest.len == 0) return error.InvalidNatsUrl;
    // host only — NatsConfig keeps default port; still dupe for ownership clarity
    const host = try allocator.dupe(u8, rest);
    return .{ host, 4222, true };
}

test "QueueNatsClient parseNatsUrl" {
    const a = std.testing.allocator;
    {
        const host, const port, const owned = try parseNatsUrl(a, "nats://127.0.0.1:4222");
        defer if (owned) a.free(host);
        try std.testing.expectEqualStrings("127.0.0.1", host);
        try std.testing.expectEqual(@as(u16, 4222), port);
    }
    {
        const host, const port, const owned = try parseNatsUrl(a, "broker.local");
        defer if (owned) a.free(host);
        try std.testing.expectEqualStrings("broker.local", host);
        try std.testing.expectEqual(@as(u16, 4222), port);
    }
}

test "QueueNatsClient offline init/deinit" {
    const a = std.testing.allocator;
    var q = QueueNatsClient.initOffline(a);
    defer q.deinit();
}

test "QueueNatsClient live publish" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const env = if (std.c.getenv("NATS_URL")) |p| std.mem.span(p) else null;
    if (env == null or env.?.len == 0) return error.SkipZigTest;

    const a = std.testing.allocator;
    const url = env.?;

    var q = try QueueNatsClient.connectWithIo(a, std.testing.io, url);
    defer q.deinit();
    try q.publish("zfinal.test.queue_nats", "hello");
    try q.ping();
}

var g_queue_nats_hits: std.atomic.Value(usize) = .init(0);

test "QueueNatsClient live publish and subscribe soak" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const env = if (std.c.getenv("NATS_URL")) |p| std.mem.span(p) else null;
    if (env == null or env.?.len == 0) return error.SkipZigTest;

    const a = std.testing.allocator;
    var q = try QueueNatsClient.connectWithIo(a, std.testing.io, env.?);
    defer q.deinit();

    g_queue_nats_hits.store(0, .monotonic);
    const sid = try q.subscribe("zfinal.test.queue_nats.soak", struct {
        fn cb(msg: QueueNatsClient.Message) void {
            if (std.mem.eql(u8, msg.payload, "queue-soak")) {
                _ = g_queue_nats_hits.fetchAdd(1, .monotonic);
            }
        }
    }.cb);
    defer q.unsubscribe(sid) catch {};

    try q.publish("zfinal.test.queue_nats.soak", "queue-soak");
    try q.flush();

    var waited: usize = 0;
    while (g_queue_nats_hits.load(.monotonic) == 0 and waited < 40) : (waited += 1) {
        _ = try q.poll();
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(25), .real) catch {};
    }
    try std.testing.expect(g_queue_nats_hits.load(.monotonic) >= 1);
}
