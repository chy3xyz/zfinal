const std = @import("std");
const nats = @import("nats");

/// NATS-backed message queue client. Requires nats.zig dependency.
///
/// Setup:
///   zig fetch --save https://github.com/nats-io/nats.zig/archive/refs/tags/v3.0.3.tar.gz
///
/// Usage:
///   var nc = try nats.Client.connect(allocator, .{ .url = "nats://localhost:4222" });
///   defer nc.deinit();
///   var q = QueueNatsClient.init(allocator, &nc);
///   try q.publish("orders.new", "{\"id\":1}");
pub const QueueNatsClient = struct {
    allocator: std.mem.Allocator,
    nc: *nats.Client,

    pub fn init(allocator: std.mem.Allocator, nc: *nats.Client) QueueNatsClient {
        return .{ .allocator = allocator, .nc = nc };
    }

    pub fn deinit(_: *QueueNatsClient) void {}

    pub fn publish(self: *const QueueNatsClient, subject: []const u8, data: []const u8) !void {
        try self.nc.publish(subject, data);
    }

    pub fn subscribe(self: *const QueueNatsClient, subject: []const u8, comptime handler: fn (Message) void) !void {
        _ = try self.nc.subscribe(subject, .{ .callback = struct {
            fn cb(m: *nats.Message) void {
                handler(.{ .subject = m.subject, .data = m.data, .reply = m.reply });
            }
        }.cb });
    }

    pub fn request(self: *const QueueNatsClient, subject: []const u8, data: []const u8, timeout_ms: u64) !Message {
        const msg = try self.nc.request(subject, data, std.time.ns_per_ms * timeout_ms);
        return .{ .subject = msg.subject, .data = msg.data, .reply = msg.reply };
    }

    pub const Message = struct { subject: []const u8, data: []const u8, reply: ?[]const u8 };
};
