const std = @import("std");
const nats = @import("nats");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const nc = try nats.Client.connect(allocator, io, "nats://localhost:4222", .{});
    defer nc.deinit();

    std.debug.print("Connected to NATS\n", .{});

    // --- Test publish ---
    try nc.publish("test.hello", "Hello from Zig!");
    try nc.flush(std.time.ns_per_s * 5);
    std.debug.print("PASS: publish\n", .{});

    // --- Test subscribe with MsgHandler vtable ---
    const SubCtx = struct {
        received: bool = false,
        pub fn onMessage(self: *@This(), msg: *const nats.Message) void {
            std.debug.print("  Received: subject={s} data={s}\n", .{ msg.subject, msg.data });
            self.received = true;
        }
    };
    var sub_ctx = SubCtx{};
    const sub = try nc.subscribe("test.sub", nats.MsgHandler.init(SubCtx, &sub_ctx));
    defer sub.deinit();

    try nc.publish("test.sub", "sub-test");
    try nc.flush(std.time.ns_per_s * 5);
    io.sleep(std.Io.Duration.fromNanoseconds(std.time.ns_per_ms * 100), .awake) catch {};
    if (sub_ctx.received) {
        std.debug.print("PASS: subscribe (MsgHandler vtable)\n", .{});
    } else {
        std.debug.print("FAIL: subscribe - no message received\n", .{});
        return error.SubscribeFailed;
    }

    // --- Test subscribeFn (plain callback, no context needed) ---
    const SubFnState = struct {
        var received: bool = false;
        fn cb(msg: *const nats.Message) void {
            std.debug.print("  Received (fn): subject={s} data={s}\n", .{ msg.subject, msg.data });
            received = true;
        }
    };
    const sub2 = try nc.subscribeFn("test.subfn", SubFnState.cb);
    defer sub2.deinit();

    try nc.publish("test.subfn", "fn-test");
    try nc.flush(std.time.ns_per_s * 5);
    io.sleep(std.Io.Duration.fromNanoseconds(std.time.ns_per_ms * 100), .awake) catch {};
    if (SubFnState.received) {
        std.debug.print("PASS: subscribeFn\n", .{});
    } else {
        std.debug.print("FAIL: subscribeFn - no message received\n", .{});
        return error.SubscribeFnFailed;
    }

    // --- Test request/reply ---
    const ReplyCtx = struct {
        client: *nats.Client,
        pub fn onMessage(self: *@This(), msg: *const nats.Message) void {
            msg.respond(self.client, "response-data") catch {};
        }
    };
    var reply_ctx = ReplyCtx{ .client = nc };
    const sub3 = try nc.subscribe("test.request", nats.MsgHandler.init(ReplyCtx, &reply_ctx));
    defer sub3.deinit();

    const resp = try nc.request("test.request", "req-data", 2000);
    if (resp) |r| {
        std.debug.print("  Response: subject={s} data={s}\n", .{ r.subject, r.data });
        std.debug.print("PASS: request/reply\n", .{});
    } else {
        std.debug.print("FAIL: request - no response (timeout)\n", .{});
        return error.RequestFailed;
    }

    std.debug.print("\nAll NATS tests passed!\n", .{});
}
