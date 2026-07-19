const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// Suitable for single-process event fan-out.
/// Cross-process: `QueueRobustMQClient` (RobustMQ / Kafka wire) or
/// `QueueNatsClient` (NATS wire, zero third-party deps).
pub const QueueClient = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    /// subject → list of subscriber mailboxes
    subs: std.StringHashMap(std.ArrayList(*Mailbox)),

    pub const Message = struct {
        subject: []const u8,
        data: []const u8,
        reply_to: ?[]const u8 = null,

        pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
            allocator.free(self.subject);
            allocator.free(self.data);
            if (self.reply_to) |r| allocator.free(r);
        }
    };

    pub const Mailbox = struct {
        allocator: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        messages: std.ArrayList(Message) = .empty,

        pub fn deinit(self: *Mailbox) void {
            for (self.messages.items) |*m| m.deinit(self.allocator);
            self.messages.deinit(self.allocator);
        }

        pub fn push(self: *Mailbox, msg: Message) !void {
            self.mutex.lockUncancelable(io_instance.io);
            defer self.mutex.unlock(io_instance.io);
            try self.messages.append(self.allocator, msg);
        }

        /// Pop one message; caller owns and must `deinit`. Returns null if empty.
        pub fn tryPop(self: *Mailbox) ?Message {
            self.mutex.lockUncancelable(io_instance.io);
            defer self.mutex.unlock(io_instance.io);
            if (self.messages.items.len == 0) return null;
            return self.messages.orderedRemove(0);
        }

        pub fn len(self: *Mailbox) usize {
            self.mutex.lockUncancelable(io_instance.io);
            defer self.mutex.unlock(io_instance.io);
            return self.messages.items.len;
        }
    };

    pub fn init(allocator: std.mem.Allocator) QueueClient {
        return .{
            .allocator = allocator,
            .subs = std.StringHashMap(std.ArrayList(*Mailbox)).init(allocator),
        };
    }

    pub fn deinit(self: *QueueClient) void {
        var it = self.subs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Mailboxes are owned by callers; only free the list shell.
            entry.value_ptr.deinit(self.allocator);
        }
        self.subs.deinit();
    }

    /// Subscribe: returns a mailbox the caller owns (must `mailbox.deinit` + destroy).
    pub fn subscribe(self: *QueueClient, subject: []const u8) !*Mailbox {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        const mb = try self.allocator.create(Mailbox);
        errdefer self.allocator.destroy(mb);
        mb.* = .{ .allocator = self.allocator };

        const gop = try self.subs.getOrPut(subject);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, subject);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, mb);
        return mb;
    }

    pub fn unsubscribe(self: *QueueClient, subject: []const u8, mailbox: *Mailbox) void {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        if (self.subs.getPtr(subject)) |list| {
            for (list.items, 0..) |m, i| {
                if (m == mailbox) {
                    _ = list.orderedRemove(i);
                    break;
                }
            }
        }
        mailbox.deinit();
        self.allocator.destroy(mailbox);
    }

    pub fn publish(self: *QueueClient, subject: []const u8, data: []const u8) !void {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        const list = self.subs.get(subject) orelse return;
        for (list.items) |mb| {
            const msg = Message{
                .subject = try self.allocator.dupe(u8, subject),
                .data = try self.allocator.dupe(u8, data),
            };
            errdefer {
                var m = msg;
                m.deinit(self.allocator);
            }
            try mb.push(msg);
        }
    }

    /// Request/reply against in-process subscribers is not supported (no network).
    pub fn request(_: *const QueueClient, _: []const u8, _: []const u8, _: u32) !?Message {
        return error.NotSupported;
    }
};

test "queue: publish delivers to subscriber" {
    const a = std.testing.allocator;
    var q = QueueClient.init(a);
    defer q.deinit();

    const mb = try q.subscribe("orders.new");
    defer q.unsubscribe("orders.new", mb);

    try q.publish("orders.new", "{\"id\":1}");
    try q.publish("other", "ignored");

    const msg = mb.tryPop() orelse return error.TestExpectedMessage;
    defer {
        var m = msg;
        m.deinit(a);
    }
    try std.testing.expectEqualStrings("orders.new", msg.subject);
    try std.testing.expectEqualStrings("{\"id\":1}", msg.data);
    try std.testing.expect(mb.tryPop() == null);
}

test "queue: fan-out to multiple subscribers" {
    const a = std.testing.allocator;
    var q = QueueClient.init(a);
    defer q.deinit();

    const mb1 = try q.subscribe("evt");
    defer q.unsubscribe("evt", mb1);
    const mb2 = try q.subscribe("evt");
    defer q.unsubscribe("evt", mb2);

    try q.publish("evt", "ping");
    try std.testing.expectEqual(@as(usize, 1), mb1.len());
    try std.testing.expectEqual(@as(usize, 1), mb2.len());
}
