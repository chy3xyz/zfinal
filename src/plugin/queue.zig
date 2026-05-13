const std = @import("std");

/// Message queue client. Stub by default (zero dependencies, always compiles).
///
/// Usage (stub — development/testing):
///   var q = QueueClient.init(allocator);
///   defer q.deinit();
///   q.publish("orders.new", payload) catch {}; // no-op in stub
///
/// Usage (NATS — production):
///   1. `zig fetch --save https://github.com/nats-io/nats.zig/archive/refs/tags/v0.1.0.tar.gz`
///   2. Import `zfinal/plugin/queue_nats.zig` and use QueueNatsClient
pub const QueueClient = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) QueueClient {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *QueueClient) void {}

    pub fn publish(_: *const QueueClient, _: []const u8, _: []const u8) !void {}

    pub fn subscribe(_: *const QueueClient, _: []const u8, _: anytype, _: anytype) !void {}

    pub fn subscribeFn(_: *const QueueClient, _: []const u8, _: anytype) !void {}

    pub fn request(_: *const QueueClient, _: []const u8, _: []const u8, _: u32) !?Message {
        return null;
    }

    pub const Message = struct { subject: []const u8, data: []const u8, reply_to: ?[]const u8 };
};
