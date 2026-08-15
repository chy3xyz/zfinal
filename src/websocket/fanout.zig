//! `WsFanout`: bridge a Queue mailbox (pub/sub) into a WebSocket sink.
//!
//! Multi-instance fanout = a cross-process pub/sub backend on the *producing*
//! side + one `WsFanout` per instance on the *receiving* side:
//!   - in-process: `zfinal.QueueClient` (memory) — useful for tests / single
//!     process fan-out to many sockets.
//!   - cross-instance: Redis `PUBLISH`/`SUBSCRIBE` (`zfinal.RedisClient`) or
//!     NATS / RobustMQ — the backend delivers into a mailbox; `WsFanout` polls
//!     it and forwards each payload to `on_message` (typically
//!     `WebSocketManager.broadcast`).
//!
//! `on_message(data)` receives a borrowed slice — copy it synchronously.

const std = @import("std");
const io_instance = @import("../io_instance.zig");
const QueueClient = @import("../plugin/queue.zig").QueueClient;
const WebSocketManager = @import("manager.zig").WebSocketManager;

pub const WsFanout = struct {
    allocator: std.mem.Allocator,
    mailbox: *QueueClient.Mailbox,
    topic: []const u8,
    on_message: *const fn (ctx: ?*anyopaque, data: []const u8) void,
    ctx: ?*anyopaque = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    const Self = @This();

    /// Spawn a background thread that drains `mailbox` and calls
    /// `on_message(ctx, data)` for each payload. The returned instance is
    /// owned by the caller — `stop()` + `destroy()` when done.
    pub fn start(
        allocator: std.mem.Allocator,
        mailbox: *QueueClient.Mailbox,
        topic: []const u8,
        on_message: *const fn (ctx: ?*anyopaque, data: []const u8) void,
        ctx: ?*anyopaque,
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .mailbox = mailbox,
            .topic = try allocator.dupe(u8, topic),
            .on_message = on_message,
            .ctx = ctx,
        };
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
        return self;
    }

    /// Convenience: forward each payload to `manager.broadcast` (the common
    /// WS fanout sink).
    pub fn startBroadcast(
        allocator: std.mem.Allocator,
        manager: *WebSocketManager,
        mailbox: *QueueClient.Mailbox,
        topic: []const u8,
    ) !*Self {
        return start(allocator, mailbox, topic, broadcastCb, manager);
    }

    fn broadcastCb(ctx: ?*anyopaque, data: []const u8) void {
        const manager: *WebSocketManager = @ptrCast(@alignCast(ctx.?));
        manager.broadcast(data) catch {};
    }

    /// Stop the loop and join the thread. Safe to call more than once.
    pub fn stop(self: *Self) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Stop + free (also frees the borrowed `topic`). Caller still owns the
    /// `mailbox`.
    pub fn destroy(self: *Self) void {
        self.stop();
        self.allocator.free(self.topic);
        self.allocator.destroy(self);
    }

    fn runLoop(self: *Self) void {
        while (self.running.load(.acquire)) {
            const msg = self.mailbox.tryPop() orelse {
                io_instance.io.sleep(std.Io.Duration.fromMilliseconds(2), .awake) catch {};
                continue;
            };
            defer {
                var m = msg;
                m.deinit(self.allocator);
            }
            self.on_message(self.ctx, msg.data);
        }
    }
};

test "WsFanout drains mailbox → callback" {
    const a = std.testing.allocator;
    var qc = QueueClient.init(a);
    defer qc.deinit();

    const mb = try qc.subscribe("ws.events");
    defer qc.unsubscribe("ws.events", mb);

    // ctx = a string sink (append payloads).
    var sink = std.array_list.Managed(u8).init(a);
    defer sink.deinit();

    const Sink = struct {
        fn on(ctx: ?*anyopaque, data: []const u8) void {
            const list: *std.array_list.Managed(u8) = @ptrCast(@alignCast(ctx.?));
            list.appendSlice(data) catch {};
        }
    };

    var f = try WsFanout.start(a, mb, "ws.events", Sink.on, &sink);
    defer f.destroy();

    try qc.publish("ws.events", "hello");
    try qc.publish("ws.events", " world");

    // Poll until the background thread drains both (bounded wait).
    var waited: usize = 0;
    while (sink.items.len < 11 and waited < 500) : (waited += 1) {
        io_instance.io.sleep(std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }
    try std.testing.expectEqualStrings("hello world", sink.items);
}
