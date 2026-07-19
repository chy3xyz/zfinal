const std = @import("std");
const QueueClient = @import("queue.zig").QueueClient;

/// Spring-style MessageQueue façade over in-process `QueueClient`.
/// Prefer `zfinal.QueueClient` for new code; this alias keeps Java migration stubs compiling.
pub const MessageQueue = struct {
    inner: QueueClient,
    allocator: std.mem.Allocator,

    pub const Mailbox = QueueClient.Mailbox;
    pub const Message = QueueClient.Message;

    /// `url` is ignored for the in-process backend (kept for Spring Cloud Stream parity).
    pub fn connect(allocator: std.mem.Allocator, url: []const u8) !MessageQueue {
        _ = url;
        return .{
            .allocator = allocator,
            .inner = QueueClient.init(allocator),
        };
    }

    pub fn close(self: *MessageQueue) void {
        self.inner.deinit();
    }

    pub fn deinit(self: *MessageQueue) void {
        self.close();
    }

    pub fn publish(self: *MessageQueue, subject: []const u8, data: []const u8) !void {
        try self.inner.publish(subject, data);
    }

    pub fn subscribe(self: *MessageQueue, subject: []const u8) !*Mailbox {
        return try self.inner.subscribe(subject);
    }

    pub fn unsubscribe(self: *MessageQueue, subject: []const u8, mailbox: *Mailbox) void {
        self.inner.unsubscribe(subject, mailbox);
    }
};

test "message queue: publish/subscribe" {
    const a = std.testing.allocator;
    var mq = try MessageQueue.connect(a, "memory://local");
    defer mq.deinit();

    const mb = try mq.subscribe("t");
    defer mq.unsubscribe("t", mb);
    try mq.publish("t", "hi");
    const msg = mb.tryPop() orelse return error.TestExpectedMessage;
    defer {
        var m = msg;
        m.deinit(a);
    }
    try std.testing.expectEqualStrings("hi", msg.data);
}
