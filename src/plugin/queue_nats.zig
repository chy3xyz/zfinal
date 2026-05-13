const std = @import("std");
const nats = @import("nats");

/// NATS-backed message queue client. Requires nats.zig v0.1.0 dependency.
///
/// Setup (in your build.zig.zon):
///   zig fetch --save https://github.com/nats-io/nats.zig/archive/refs/tags/v0.1.0.tar.gz
///
/// Usage:
///   var threaded = std.Io.Threaded.init(allocator, .{});
///   var nc = try nats.Client.connect(allocator, threaded.io(), "nats://localhost:4222", .{});
///   defer nc.deinit();
///   var q = QueueNatsClient.init(allocator, nc);
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

    /// Subscribe with a context object whose onMessage(msg: *const nats.Message) void is called.
    /// Uses nats.zig MsgHandler vtable pattern.
    pub fn subscribe(self: *const QueueNatsClient, subject: []const u8, comptime T: type, ctx: *T) !void {
        _ = try self.nc.subscribe(subject, nats.MsgHandler.init(T, ctx));
    }

    /// Subscribe with a plain function pointer (no context needed).
    pub fn subscribeFn(self: *const QueueNatsClient, subject: []const u8, cb: *const fn (*const nats.Message) void) !void {
        _ = try self.nc.subscribeFn(subject, cb);
    }

    /// Request/reply with timeout. Returns null if no responder within timeout_ms.
    pub fn request(self: *const QueueNatsClient, subject: []const u8, data: []const u8, timeout_ms: u32) !?Message {
        if (try self.nc.request(subject, data, timeout_ms)) |m| {
            return .{ .subject = m.subject, .data = m.data, .reply_to = m.reply_to };
        }
        return null;
    }

    pub const Message = struct { subject: []const u8, data: []const u8, reply_to: ?[]const u8 };
};
